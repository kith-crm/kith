defmodule KithWeb.DAV.ConcurrencyTest do
  @moduledoc """
  Concurrent CardDAV writes. These run outside the Ecto sandbox (real
  transactions and row locks), so the module is not async and every test
  deletes its account afterwards.
  """
  use KithWeb.ConnCase, async: false

  import Ecto.Query
  import KithWeb.DAV.TestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.{Contacts, Repo}

  @book "/dav/addressbooks/default/"

  setup do
    user = Sandbox.unboxed_run(Repo, fn -> Kith.AccountsFixtures.user_fixture() end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Kith.Accounts.Account, where: a.id == ^user.account_id)
      end)
    end)

    %{user: user, account_id: user.account_id}
  end

  defp dav_put(user, href, vcard, headers \\ []) do
    Sandbox.unboxed_run(Repo, fn ->
      headers
      |> Enum.reduce(build_conn(), fn {k, v}, c -> put_req_header(c, k, v) end)
      |> basic_auth(user.email, dav_password())
      |> dav_request("PUT", href, vcard)
    end)
  end

  defp card(tel), do: build_vcard("Race", "Card", phone: tel)

  defp tels(account_id, href) do
    Sandbox.unboxed_run(Repo, fn ->
      name = href |> String.split("/") |> List.last()
      contact = Contacts.get_contact_by_dav_name(account_id, name)
      contact.id |> Contacts.list_contact_fields() |> Enum.map(& &1.value)
    end)
  end

  describe "CDV-24: preconditions are evaluated under a row lock" do
    test "CDV-24: a PUT whose If-Match is overtaken by an uncommitted write is 412, not a lost update",
         %{user: user, account_id: account_id} do
      href = @book <> "lock.vcf"
      created = dav_put(user, href, card("+15550000000"))
      assert created.status == 201
      [etag] = get_resp_header(created, "etag")

      # Another writer changes the contact and holds its row lock while the
      # PUT (carrying the now-stale ETag) runs; it commits half a second later.
      task =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, task} =
            Repo.transaction(fn ->
              contact = Contacts.get_contact_by_dav_name(account_id, "lock.vcf")
              {:ok, _} = Contacts.update_contact(contact, %{"last_name" => "Other"})

              {:ok, _} =
                Contacts.replace_contact_children(contact, account_id, %{
                  emails: [],
                  phones: [%{value: "+15559999999", label: "cell"}],
                  urls: [],
                  addresses: []
                })

              task =
                Task.async(fn ->
                  dav_put(user, href, card("+15551111111"), [{"if-match", etag}])
                end)

              Process.sleep(500)
              task
            end)

          task
        end)

      assert Task.await(task, 10_000).status == 412
      assert tels(account_id, href) == ["+15559999999"]
    end

    test "CDV-24: two concurrent PUTs with the same If-Match: one 2xx, one 412, children of one body",
         %{user: user, account_id: account_id} do
      href = @book <> "pair.vcf"
      created = dav_put(user, href, card("+15550000000"))
      [etag] = get_resp_header(created, "etag")

      results =
        ["+15551111111", "+15552222222"]
        |> Enum.map(fn tel ->
          Task.async(fn -> {tel, dav_put(user, href, card(tel), [{"if-match", etag}]).status} end)
        end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert results |> Enum.map(&elem(&1, 1)) |> Enum.sort() == [204, 412]
      [{winner, 204}] = Enum.filter(results, &(elem(&1, 1) == 204))
      assert tels(account_id, href) == [winner]
    end
  end

  describe "CDV-25: concurrent creates of one name" do
    # Another writer creates `name` and holds the transaction open while the PUT
    # runs, then commits: the PUT's insert hits the unique index.
    defp put_during_create(user, account_id, name, headers) do
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, task} =
          Repo.transaction(fn ->
            {:ok, c} = Contacts.create_contact(account_id, %{"first_name" => "First"})
            {:ok, _} = Contacts.put_dav_identity(c, %{dav_resource_name: name})

            task =
              Task.async(fn -> dav_put(user, @book <> name, card("+15553333333"), headers) end)

            Process.sleep(500)
            task
          end)

        Task.await(task, 10_000)
      end)
    end

    defp count(account_id),
      do: Sandbox.unboxed_run(Repo, fn -> Contacts.count_contacts(account_id) end)

    test "CDV-25: the losing unconditional create becomes an update of the winner",
         %{user: user, account_id: account_id} do
      assert put_during_create(user, account_id, "race.vcf", []).status == 204
      assert count(account_id) == 1
      assert tels(account_id, @book <> "race.vcf") == ["+15553333333"]
    end

    test "CDV-25: the losing If-None-Match: * create is 412",
         %{user: user, account_id: account_id} do
      assert put_during_create(user, account_id, "race2.vcf", [{"if-none-match", "*"}]).status ==
               412

      assert count(account_id) == 1
    end
  end
end
