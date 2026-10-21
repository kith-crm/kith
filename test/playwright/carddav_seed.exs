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

  # Each contact: 2 fields (email + phone), 1 address, 1 tag. Goes through the
  # app's insert paths, so it also measures the child -> parent DAV triggers.
  field_types = Contacts.list_contact_field_types(perf.account_id)
  email_type = Enum.find(field_types, &(&1.protocol == "mailto:"))
  phone_type = Enum.find(field_types, &(&1.protocol == "tel:"))

  tag =
    case Repo.get_by(Kith.Contacts.Tag, account_id: perf.account_id, name: "perf") do
      nil ->
        {:ok, tag} = Contacts.create_tag(perf.account_id, %{name: "perf"})
        tag

      tag ->
        tag
    end

  started = System.monotonic_time(:millisecond)
  perf_count = String.to_integer(System.get_env("PERF_COUNT", "2000"))

  for i <- (have + 1)..perf_count//1 do
    {:ok, contact} =
      Contacts.create_contact(perf.account_id, %{
        first_name: "Perf#{i}",
        last_name: "Contact",
        display_name: "Perf#{i} Contact"
      })

    {:ok, _} =
      Contacts.create_contact_field(contact, %{
        value: "perf#{i}@example.test",
        contact_field_type_id: email_type.id
      })

    {:ok, _} =
      Contacts.create_contact_field(contact, %{
        value: "+1555#{String.pad_leading("#{i}", 7, "0")}",
        contact_field_type_id: phone_type.id
      })

    {:ok, _} =
      Contacts.create_address(contact, %{
        line1: "#{i} Perf Street",
        city: "Perfville",
        country: "US"
      })

    Contacts.tag_contact(contact, tag)
  end

  elapsed = System.monotonic_time(:millisecond) - started

  IO.puts(
    "==> carddav seed: perf account has #{perf_count} contacts (seeded #{max(perf_count - have, 0)} in #{elapsed} ms)"
  )
end

IO.puts("==> carddav seed: users ready")
