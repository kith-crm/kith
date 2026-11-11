defmodule Kith.Accounts.OIDCTest do
  use Kith.DataCase
  alias Kith.Accounts
  alias Kith.Accounts.{Account, OIDC}
  alias Kith.Auth.Principal
  import Kith.AccountsFixtures

  setup do
    auth = Application.fetch_env!(:kith, :auth)
    tos = Application.get_env(:kith, :require_tos_acceptance)
    providers = Application.get_env(:kith, :oauth_providers)
    passkeys = Application.get_env(:kith, :passkeys_enabled)

    Application.put_env(:kith, :auth, %{
      auth
      | oidc_enabled: true,
        registration_enabled: true,
        oidc: [issuer: "https://issuer.test"]
    })

    on_exit(fn ->
      Application.put_env(:kith, :auth, auth)
      Application.put_env(:kith, :require_tos_acceptance, tos)
      Application.put_env(:kith, :oauth_providers, providers)
      Application.put_env(:kith, :passkeys_enabled, passkeys)
    end)

    :ok
  end

  defp principal(attrs \\ %{}) do
    struct!(
      Principal,
      Map.merge(
        %{
          issuer: "https://issuer.test",
          subject: "external-1",
          email: unique_user_email(),
          email_verified: true,
          name: "Alex"
        },
        attrs
      )
    )
  end

  defp fresh(user), do: %{user | authenticated_at: DateTime.utc_now(:second)}

  defp policy(attrs),
    do: Application.put_env(:kith, :auth, Map.merge(Application.fetch_env!(:kith, :auth), attrs))

  test "verified matching email never links an existing account" do
    user = Kith.AccountsFixtures.user_fixture()

    principal = %Kith.Auth.Principal{
      issuer: "https://issuer.test",
      subject: "external-1",
      email: user.email,
      email_verified: true,
      name: "Alex"
    }

    assert {:error, :email_collision} = Kith.Accounts.OIDC.resolve(principal)
    assert [] = Kith.Accounts.OIDC.list(user)
  end

  test "register creates only a personal account, confirmed passwordless user and defaults" do
    p = principal(%{name: "  <b>Alex</b>  "})
    assert {:error, :registration_required} = OIDC.resolve(p)
    assert {:ok, user} = OIDC.register(p, %{tos_accepted: true, role: "viewer", account_id: 9})
    assert user.hashed_password == nil
    assert user.role == "admin"
    assert user.confirmed_at
    assert user.display_name == "Alex"
    assert user.account.id == user.account_id

    assert Repo.aggregate(
             from(r in Kith.Reminders.ReminderRule, where: r.account_id == ^user.account_id),
             :count
           ) > 0

    assert [%{issuer: "https://issuer.test", subject: "external-1"}] = OIDC.list(user)
  end

  test "known identity ignores disabled signup and later missing or unverified email without synchronization" do
    p = principal()
    {:ok, user} = OIDC.register(p, %{})
    policy(%{registration_enabled: false})

    for email <- [nil, "changed@example.test"], verified <- [nil, false, "true"] do
      assert {:ok, returned} = OIDC.resolve(%{p | email: email, email_verified: verified})
      assert returned.id == user.id
      assert returned.email == user.email
    end

    assert {:error, :registration_disabled} = OIDC.register(principal(%{subject: "new"}), %{})
  end

  test "only actual verified boolean permits signup" do
    for verified <- [nil, false, "true", 1] do
      assert {:error, :email_unverified} =
               OIDC.register(principal(%{email_verified: verified}), %{})
    end
  end

  test "email validation, uniqueness and terms are retained and failures leave no orphan accounts" do
    initial = Repo.aggregate(Account, :count)

    for email <- [
          nil,
          "bad",
          "bad email@example.test",
          String.duplicate("a", 150) <> "@example.test"
        ] do
      assert {:error, %Ecto.Changeset{}} = OIDC.register(principal(%{email: email}), %{})
    end

    user = user_fixture()
    count = Repo.aggregate(Account, :count)
    assert count == initial + 1

    assert {:error, :email_collision} =
             OIDC.register(principal(%{email: String.upcase(user.email)}), %{})

    Application.put_env(:kith, :require_tos_acceptance, true)
    assert {:error, changeset} = OIDC.register(principal(), %{})
    assert errors_on(changeset).tos_accepted
    assert Repo.aggregate(Account, :count) == count
    assert {:ok, accepted} = OIDC.register(principal(), %{tos_accepted: true})
    assert accepted.tos_accepted_at
  end

  test "identity insertion failure rolls back account, user and defaults" do
    before =
      {Repo.aggregate(Account, :count), Repo.aggregate(Kith.Accounts.User, :count),
       Repo.aggregate(Kith.Reminders.ReminderRule, :count)}

    assert {:error, %Ecto.Changeset{}} = OIDC.register(principal(%{subject: ""}), %{})

    assert {Repo.aggregate(Account, :count), Repo.aggregate(Kith.Accounts.User, :count),
            Repo.aggregate(Kith.Reminders.ReminderRule, :count)} == before
  end

  test "identity keys remain exact without trimming or case normalization" do
    p = principal(%{subject: " Subject "})
    {:ok, user} = OIDC.register(p, %{})
    assert [%{subject: " Subject "}] = OIDC.list(user)
    assert {:error, :email_collision} = OIDC.resolve(%{p | subject: "Subject"})
    assert {:error, :email_collision} = OIDC.resolve(%{p | issuer: "https://ISSUER.test"})
  end

  test "same subject on different issuers cannot capture an existing account" do
    p = principal()
    {:ok, user} = OIDC.register(p, %{})
    other = %{p | issuer: "https://other.test"}
    assert {:error, :email_collision} = OIDC.resolve(other)
    {:ok, separate} = OIDC.register(%{other | email: unique_user_email()}, %{})
    refute separate.id == user.id
    refute separate.account_id == user.account_id
    assert {:ok, same} = OIDC.register(p, %{})
    assert same.id == user.id
  end

  test "link requires recent local auth and cannot transfer ownership" do
    user = user_fixture()
    other = user_fixture()
    p = principal(%{email: other.email})

    for timestamp <- [
          nil,
          DateTime.add(DateTime.utc_now(), -1201),
          DateTime.add(DateTime.utc_now(), 60)
        ] do
      assert {:error, :reauthentication_required} =
               OIDC.link(%{user | authenticated_at: timestamp}, p)
    end

    assert {:ok, identity} = OIDC.link(fresh(user), p)
    assert identity.user_id == user.id
    assert {:ok, again} = OIDC.link(fresh(user), p)
    assert again.id == identity.id
    assert {:error, :identity_in_use} = OIDC.link(fresh(other), p)
    assert [] == OIDC.list(other)
  end

  test "database identity uniqueness rejects another owner without altering the original" do
    user = user_fixture()
    other = user_fixture()
    p = principal()
    {:ok, identity} = OIDC.link(fresh(user), p)

    changeset =
      Kith.Accounts.OIDCIdentity.changeset(%Kith.Accounts.OIDCIdentity{}, %{
        issuer: p.issuer,
        subject: p.subject,
        user_id: other.id
      })

    assert {:error, rejected} = Repo.insert(changeset)
    assert errors_on(rejected).issuer
    assert [%{id: id, user_id: owner}] = OIDC.list(user)
    assert id == identity.id
    assert owner == user.id
    assert [] == OIDC.list(other)
  end

  test "removal re-reads persisted password state instead of trusting a stale user" do
    user = user_fixture()
    {:ok, identity} = OIDC.link(fresh(user), principal())
    Repo.update!(change(user, hashed_password: nil))
    assert {:error, :last_login_method} = OIDC.unlink(fresh(user), identity.id)
  end

  test "persisted MFA cannot be bypassed with stale user state during provisional sudo phase" do
    user = user_fixture()
    {:ok, identity} = OIDC.link(fresh(user), principal())
    Repo.update!(change(user, totp_enabled: true))

    assert {:error, :reauthentication_required} =
             OIDC.link(fresh(user), principal(%{subject: "next"}))

    assert {:error, :reauthentication_required} = OIDC.unlink(fresh(user), identity.id)
  end

  test "unlink is scoped, fresh and refuses last usable method including disabled password" do
    user = user_fixture()
    other = user_fixture()
    {:ok, identity} = OIDC.link(fresh(user), principal())
    assert {:error, :reauthentication_required} = OIDC.unlink(user, identity.id)
    assert {:error, :not_found} = OIDC.unlink(fresh(other), identity.id)
    assert {:error, :not_found} = OIDC.unlink(fresh(user), "bad")
    policy(%{password_login_enabled: false})
    assert {:error, :last_login_method} = OIDC.unlink(fresh(user), identity.id)
    policy(%{password_login_enabled: true})
    assert :ok = OIDC.unlink(fresh(user), identity.id)
    assert [] = OIDC.list(user)
  end

  test "configured issuers, legacy providers and existing passkeys count as alternatives" do
    {:ok, user} = OIDC.register(principal(), %{})
    [identity] = OIDC.list(user)
    {:ok, legacy} = Accounts.upsert_identity(user, "github", "legacy", %{})
    Application.put_env(:kith, :oauth_providers, %{})
    assert {:error, :last_login_method} = OIDC.unlink(fresh(user), identity.id)

    Application.put_env(:kith, :oauth_providers, %{
      github: [client_id: "id", client_secret: "secret"]
    })

    assert :ok = OIDC.unlink(fresh(user), identity.id)
    assert {:error, :last_login_method} = Accounts.delete_identity(user, legacy.id)
    {:ok, _} = OIDC.link(fresh(user), principal())
    policy(%{oidc: [issuer: "https://changed.test"]})
    assert {:error, :last_login_method} = Accounts.delete_identity(user, legacy.id)
    policy(%{oidc: [issuer: "https://issuer.test"]})
    assert {:ok, _} = Accounts.delete_identity(user, legacy.id)

    credential =
      Repo.insert!(%Accounts.WebauthnCredential{
        user_id: user.id,
        credential_id: <<1, 2>>,
        public_key: :erlang.term_to_binary(%{}),
        name: "key"
      })

    Application.put_env(:kith, :passkeys_enabled, false)
    assert :ok = OIDC.unlink(fresh(user), hd(OIDC.list(user)).id)
    assert {:error, :last_credential} = Accounts.delete_webauthn_credential(user, credential.id)
  end

  test "passwordless users can remove one of two passkeys without the startup capability flag" do
    Application.put_env(:kith, :passkeys_enabled, false)
    user = user_fixture() |> change(hashed_password: nil) |> Repo.update!()

    credentials =
      for id <- [1, 2] do
        Repo.insert!(%Accounts.WebauthnCredential{
          user_id: user.id,
          credential_id: <<id>>,
          public_key: :erlang.term_to_binary(%{}),
          name: "key #{id}"
        })
      end

    [first, remaining] = credentials
    assert {:ok, _} = Accounts.delete_webauthn_credential(user, first.id)
    assert [%{id: id}] = Accounts.list_webauthn_credentials(user)
    assert id == remaining.id
    assert Accounts.has_login_method?(user)
    assert {:error, :last_credential} = Accounts.delete_webauthn_credential(user, remaining.id)
    assert [%{id: ^id}] = Accounts.list_webauthn_credentials(user)
  end

  test "app passwords do not count and identity rows cascade on user deletion" do
    {:ok, user} = OIDC.register(principal(), %{})
    {:ok, _, _} = Accounts.DavAppPasswords.create(fresh(user), %{name: "Phone"})
    [identity] = OIDC.list(user)
    assert {:error, :last_login_method} = OIDC.unlink(fresh(user), identity.id)
    Repo.delete!(user)
    assert OIDC.list(user) == []
  end
end

defmodule Kith.Accounts.OIDCConcurrencyTest do
  use ExUnit.Case, async: false
  @moduletag :oidc_concurrency
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Kith.Accounts
  alias Kith.Accounts.{Account, OIDC, OIDCIdentity, User, WebauthnCredential}
  alias Kith.Auth.Principal
  alias Kith.Repo

  setup do
    auth = Application.fetch_env!(:kith, :auth)
    providers = Application.get_env(:kith, :oauth_providers)
    passkeys = Application.get_env(:kith, :passkeys_enabled)
    suffix = Ecto.UUID.generate()
    email = "oidc-race-#{suffix}@example.test"

    p = %Principal{
      issuer: "https://issuer.test",
      subject: "race-#{suffix}",
      email: email,
      email_verified: true
    }

    Application.put_env(:kith, :auth, %{
      auth
      | oidc_enabled: true,
        registration_enabled: true,
        password_login_enabled: false,
        oidc: [issuer: p.issuer]
    })

    Application.put_env(:kith, :oauth_providers, %{
      github: [client_id: "id", client_secret: "secret"]
    })

    Application.put_env(:kith, :passkeys_enabled, true)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids = Repo.all(from(u in User, where: u.email == ^email, select: u.account_id))
        Repo.delete_all(from(a in Account, where: a.id in ^ids))
      end)

      Application.put_env(:kith, :auth, auth)
      Application.put_env(:kith, :oauth_providers, providers)
      Application.put_env(:kith, :passkeys_enabled, passkeys)
    end)

    %{principal: p}
  end

  test "concurrent first signup uses independent connections and creates one account/default set",
       %{principal: p} do
    tasks =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, tasks} =
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
              Jason.encode!([p.issuer, p.subject])
            ])

            concurrent_waiters([fn -> OIDC.register(p, %{}) end, fn -> OIDC.register(p, %{}) end])
          end)

        tasks
      end)

    [first, second] = Enum.map(tasks, &Task.await(&1, 10_000))
    assert {:ok, user} = first
    assert {:ok, same} = second
    assert same.id == user.id

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(from(u in User, where: u.email == ^p.email), :count) == 1
      assert Repo.aggregate(from(i in OIDCIdentity, where: i.user_id == ^user.id), :count) == 1

      rules =
        Repo.all(from(r in Kith.Reminders.ReminderRule, where: r.account_id == ^user.account_id))

      assert Enum.sort(Enum.map(rules, & &1.days_before)) == [0, 7, 30]
    end)
  end

  test "email collision at database write rolls back the new personal account", %{principal: p} do
    {task, account_count} =
      Sandbox.unboxed_run(Repo, fn ->
        before = Repo.aggregate(Account, :count)

        {:ok, task} =
          Repo.transaction(fn ->
            {:ok, _user} = OIDC.register(%{p | subject: p.subject <> "-owner"}, %{})
            [task] = concurrent_waiters([fn -> OIDC.register(p, %{}) end])
            task
          end)

        {task, before}
      end)

    assert {:error, :email_collision} = Task.await(task, 10_000)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(Account, :count) == account_count + 1
      assert {:error, :email_collision} = OIDC.resolve(p)
    end)
  end

  for alternate <- [:oidc, :legacy, :passkey] do
    @alternate alternate
    test "concurrent OIDC and #{@alternate} removals cannot remove both final methods", %{
      principal: p
    } do
      {user, tasks} =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, user} = OIDC.register(p, %{})
          user = %{user | authenticated_at: DateTime.utc_now(:second)}
          [first] = OIDC.list(user)

          remove_other =
            case @alternate do
              :oidc ->
                {:ok, second} = OIDC.link(user, %{p | subject: p.subject <> "-second"})
                fn -> OIDC.unlink(user, second.id) end

              :legacy ->
                {:ok, legacy} = Accounts.upsert_identity(user, "github", p.subject, %{})
                fn -> Accounts.delete_identity(user, legacy.id) end

              :passkey ->
                key =
                  Repo.insert!(%WebauthnCredential{
                    user_id: user.id,
                    credential_id: :crypto.strong_rand_bytes(32),
                    public_key: :erlang.term_to_binary(%{}),
                    name: "key"
                  })

                fn -> Accounts.delete_webauthn_credential(user, key.id) end
            end

          {:ok, tasks} =
            Repo.transaction(fn ->
              Repo.one!(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE"))
              concurrent_waiters([fn -> OIDC.unlink(user, first.id) end, remove_other])
            end)

          {user, tasks}
        end)

      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.count(
               results,
               &match?({:error, reason} when reason in [:last_login_method, :last_credential], &1)
             ) == 1

      assert Enum.count(results, &(&1 == :ok or match?({:ok, _}, &1))) == 1
      Sandbox.unboxed_run(Repo, fn -> assert Accounts.has_login_method?(user) end)
    end
  end

  defp concurrent_waiters(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn fun ->
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:backend, backend})

            receive do
              :start -> fun.()
            end
          end)
        end)
      end)

    backends =
      Enum.map(tasks, fn _ ->
        assert_receive {:backend, backend}, 5_000
        backend
      end)

    assert length(Enum.uniq(backends)) == length(tasks)
    Enum.each(tasks, &send(&1.pid, :start))
    Enum.each(backends, &wait_for_lock(&1, 200))
    tasks
  end

  defp wait_for_lock(pid, attempts) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [pid])

    cond do
      blocked ->
        :ok

      attempts == 0 ->
        flunk("mutation did not wait on the database lock")

      true ->
        Process.sleep(10)
        wait_for_lock(pid, attempts - 1)
    end
  end
end
