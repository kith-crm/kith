defmodule KithWeb.DAV.ConcurrencyTest do
  use KithWeb.ConnCase, async: false
  import Ecto.Query
  import KithWeb.DAV.TestHelpers
  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Contacts, Repo}
  alias Kith.DAV.Store

  setup do
    user = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture() end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Kith.Accounts.Account, where: a.id == ^user.account_id)
      end)
    end)

    %{user: user, account_id: user.account_id}
  end

  defp request(user, method, href, headers \\ [], opts \\ []) do
    Sandbox.unboxed_run(Repo, fn ->
      headers
      |> Enum.reduce(build_conn(), fn {key, value}, conn -> put_req_header(conn, key, value) end)
      |> basic_auth(user.email, dav_password())
      |> dav_request(method, href, build_vcard("Concurrent", "Card", opts))
    end)
  end

  test "concurrent creates at one name produce one contact", %{user: user, account_id: aid} do
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> request(user, "PUT", "/dav/addressbooks/default/race.vcf")
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :go))
    assert Enum.map(tasks, &Task.await(&1, 10_000).status) |> Enum.sort() == [201, 204]
    assert Sandbox.unboxed_run(Repo, fn -> Contacts.count_contacts(aid) end) == 1
  end

  test "concurrent creates with equivalent UUID forms have one winner", %{
    user: user,
    account_id: aid
  } do
    uuid = Ecto.UUID.generate()

    tasks =
      [String.upcase(uuid), "urn:uuid:" <> uuid]
      |> Enum.with_index()
      |> Enum.map(fn {uid, index} ->
        Task.async(fn ->
          request(user, "PUT", "/dav/addressbooks/default/uuid-race-#{index}.vcf", [], uid: uid)
        end)
      end)

    assert Enum.map(tasks, &Task.await(&1, 10_000).status) |> Enum.sort() == [201, 409]
    assert Sandbox.unboxed_run(Repo, fn -> Contacts.count_contacts(aid) end) == 1
  end

  test "two concurrent conditional updates have one winner", %{user: user} do
    href = "/dav/addressbooks/default/conditional.vcf"
    assert request(user, "PUT", href).status == 201
    [etag] = request(user, "GET", href) |> get_resp_header("etag")

    tasks =
      for _ <- 1..2, do: Task.async(fn -> request(user, "PUT", href, [{"if-match", etag}]) end)

    assert Enum.map(tasks, &Task.await(&1, 10_000).status) |> Enum.sort() == [204, 412]
  end

  test "DELETE with a stale If-Match is 412", %{user: user} do
    href = "/dav/addressbooks/default/delete.vcf"
    assert request(user, "PUT", href).status == 201
    [etag] = request(user, "GET", href) |> get_resp_header("etag")
    assert request(user, "PUT", href).status == 204
    assert request(user, "DELETE", href, [{"if-match", etag}]).status == 412
    assert request(user, "GET", href).status == 200
  end

  test "a database deadlock returns 503 with Retry-After", %{user: user, account_id: aid} do
    href = "/dav/addressbooks/default/deadlock.vcf"
    assert request(user, "PUT", href).status == 201
    parent = self()

    blocker =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL deadlock_timeout = '5s'")
            Store.get_by_resource_name(aid, "deadlock.vcf") |> Store.lock()
            send(parent, :locked)

            receive do
              :account -> Store.transaction(aid, fn -> :ok end)
            end
          end)
        end)
      end)

    assert_receive :locked

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("SET deadlock_timeout = '50ms'")

          try do
            request(user, "PUT", href)
          after
            Repo.query!("RESET deadlock_timeout")
          end
        end)
      end)

    Sandbox.unboxed_run(Repo, fn -> wait_for_lock() end)
    send(blocker.pid, :account)
    response = Task.await(writer, 10_000)
    assert response.status == 503
    assert get_resp_header(response, "retry-after") == ["1"]
    Task.await(blocker, 10_000)
  end

  defp wait_for_lock(tries \\ 250) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    cond do
      count > 0 ->
        :ok

      tries == 0 ->
        flunk("writer never waited for the row lock")

      true ->
        Process.sleep(20)
        wait_for_lock(tries - 1)
    end
  end
end
