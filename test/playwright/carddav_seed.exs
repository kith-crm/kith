# CardDAV E2E seeder.
#
# Usage (see scripts/carddav-e2e/up.sh):
#   MIX_ENV=dev DB_NAME=kith_carddav_e2e mix run test/playwright/carddav_seed.exs
#   PERF=1 ... adds account E with 2000 contacts.
#
# Idempotent: safe to run repeatedly.

import Ecto.Query

alias Kith.Repo
alias Kith.Accounts
alias Kith.Accounts.User
alias Kith.Contacts
alias Kith.Contacts.Contact

db = Repo.config()[:database]

if db == "kith_dev" or String.starts_with?(db, "kith_test") do
  raise "carddav_seed refuses to run against #{db}"
end

Code.eval_file("priv/repo/seeds.exs")

password = "ValidP@ssword123!"
now = DateTime.utc_now(:second)

ensure_user = fn email ->
  case Repo.get_by(User, email: email) do
    nil ->
      {:ok, user} = Accounts.register_user(%{email: email, password: password})
      Repo.get!(User, user.id)

    existing ->
      existing
  end
end

confirm = fn user ->
  user |> Ecto.Changeset.change(confirmed_at: now) |> Repo.update!()
end

# Account A: admin, editor, viewer
admin = ensure_user.("dav-admin@carddav.test") |> confirm.()

for {email, role} <- [
      {"dav-editor@carddav.test", "editor"},
      {"dav-viewer@carddav.test", "viewer"}
    ] do
  user = ensure_user.(email)

  user
  |> Ecto.Changeset.change(confirmed_at: now, role: role, account_id: admin.account_id)
  |> Repo.update!()
end

# Account B: other admin
ensure_user.("dav-other@carddav.test") |> confirm.()

# Account C: TOTP-enabled admin
totp = ensure_user.("dav-totp@carddav.test") |> confirm.()

if is_nil(totp.totp_secret) or not totp.totp_enabled do
  totp
  |> Ecto.Changeset.change(
    totp_enabled: true,
    totp_secret: Accounts.generate_totp_secret()
  )
  |> Repo.update!()
end

# Account D: unconfirmed admin
unconfirmed = ensure_user.("dav-unconfirmed@carddav.test")
unconfirmed |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()

# Account E: perf (opt-in)
if System.get_env("PERF") == "1" do
  perf = ensure_user.("dav-perf@carddav.test") |> confirm.()

  have =
    Repo.aggregate(
      from(c in Contact, where: c.account_id == ^perf.account_id),
      :count
    )

  for i <- (have + 1)..2000//1 do
    {:ok, _} =
      Contacts.create_contact(perf.account_id, %{
        first_name: "Perf#{i}",
        last_name: "Contact",
        display_name: "Perf#{i} Contact"
      })
  end

  IO.puts("==> carddav seed: perf account has 2000 contacts")
end

IO.puts("==> carddav seed: users ready")
