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

  perf_count = String.to_integer(System.get_env("PERF_COUNT", "2000"))
  account_id = perf.account_id

  # Seeded contacts are `Perf<i> Contact`, i in 1..perf_count. Re-running is
  # idempotent: missing contacts are created and missing children (fields,
  # address, tag) are backfilled, whether the contact is new or came from an
  # earlier seed. Other contacts of the account (probe leftovers) are ignored.
  existing =
    from(c in Contact,
      where:
        c.account_id == ^account_id and c.last_name == "Contact" and like(c.first_name, "Perf%"),
      select: {c.first_name, c}
    )
    |> Repo.all()
    |> Map.new()

  trashed = for {name, c} <- existing, c.deleted_at != nil or c.is_archived, do: name

  if trashed != [] do
    raise "carddav_seed: #{length(trashed)} seeded perf contacts are trashed or archived " <>
            "(e.g. #{hd(trashed)}); reseed from scratch with " <>
            "`scripts/carddav-e2e/down.sh && PERF=1 scripts/carddav-e2e/up.sh` on a fresh database"
  end

  with_children = fn table ->
    from(r in table,
      where: r.account_id == ^account_id or is_nil(r.account_id),
      select: r.contact_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  has_fields = with_children.("contact_fields")
  has_address = with_children.("addresses")

  has_tag =
    from(ct in "contact_tags",
      join: c in Contact,
      on: c.id == ct.contact_id,
      where: c.account_id == ^account_id,
      select: ct.contact_id
    )
    |> Repo.all()
    |> MapSet.new()

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

  for i <- 1..perf_count//1 do
    contact =
      case Map.fetch(existing, "Perf#{i}") do
        {:ok, contact} ->
          contact

        :error ->
          {:ok, contact} =
            Contacts.create_contact(account_id, %{
              first_name: "Perf#{i}",
              last_name: "Contact",
              display_name: "Perf#{i} Contact"
            })

          contact
      end

    unless MapSet.member?(has_fields, contact.id) do
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
    end

    unless MapSet.member?(has_address, contact.id) do
      {:ok, _} =
        Contacts.create_address(contact, %{
          line1: "#{i} Perf Street",
          city: "Perfville",
          country: "US"
        })
    end

    unless MapSet.member?(has_tag, contact.id), do: Contacts.tag_contact(contact, tag)
  end

  # Leftovers of the near-cap card test (07-perf.spec.ts soft-deletes it).
  {removed, _} =
    Repo.delete_all(
      from(c in Contact,
        where: c.account_id == ^account_id and like(c.dav_resource_name, "cdv-perf-%")
      )
    )

  elapsed = System.monotonic_time(:millisecond) - started

  IO.puts(
    "==> carddav seed: perf account has #{perf_count} contacts (#{map_size(existing)} already there, #{removed} probe leftovers removed, #{elapsed} ms)"
  )
end

IO.puts("==> carddav seed: users ready")
