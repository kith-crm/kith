# CardDAV E2E seeder.
#
# Usage (see scripts/carddav-e2e/up.sh):
#   MIX_ENV=dev DB_NAME=kith_carddav_task10_e2e mix run test/playwright/carddav_seed.exs
#   PERF=1 ... adds account E with 2000 contacts.
#
# Idempotent: safe to run repeatedly.

import Ecto.Query

alias Kith.Repo
alias Kith.Accounts
alias Kith.Accounts.User
alias Kith.Contacts
alias Kith.Contacts.Contact
alias Kith.DAV.{FieldRegistry, Store, VCardAdapter}

db = Repo.config()[:database]

if db != "kith_carddav_task10_e2e" do
  raise "carddav_seed refuses to run against #{db}"
end

# Keep fixture setup from inspecting every document in debug SQL logs.
Logger.configure(level: :warning)
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

# Real-client fixtures live in account A; account B remains available for CLI runs.
# All visible writes use application functions so DAV revisions are exercised.
unless Repo.get_by(Contact, account_id: admin.account_id, first_name: "Client", last_name: "Seed") do
  {:ok, seed} =
    Contacts.create_contact(admin.account_id, %{
      first_name: "Client",
      last_name: "Seed",
      birthdate: ~D[2000-07-14],
      birthdate_year_unknown: true,
      description: "Private Kith seed description"
    })

  for {kind, value} <- [{:phones, "+15550101001"}, {:emails, "seed@example.test"}] do
    type = FieldRegistry.canonical_type!(kind)

    {:ok, _} =
      Contacts.create_contact_field(seed, %{value: value, contact_field_type_id: type.id})
  end

  {:ok, _} =
    Contacts.create_address(seed, %{
      line1: "14 Client Street",
      city: "Testville",
      postal_code: "12345",
      country: "US"
    })

  for name <- ["Client Friends", "Client Family"] do
    {:ok, tag} = Contacts.create_tag(admin.account_id, %{name: name})
    {1, _} = Contacts.tag_contact(seed, tag)
  end

  # Generate a real decodable image so photo checks need no external service.
  photo_data =
    Image.new!(640, 480, color: [30, 100, 180]) |> Image.write!(:memory, suffix: ".jpg")

  key = Kith.Storage.generate_key(admin.account_id, "photos", "client-seed.jpg")
  {:ok, _} = Kith.Storage.upload_binary(photo_data, key)

  {:ok, photo} =
    Contacts.create_photo(seed, %{
      file_name: "client-seed.jpg",
      storage_key: key,
      file_size: byte_size(photo_data),
      content_type: "image/jpeg"
    })

  {:ok, _} = Contacts.set_avatar(seed, photo)

  {:ok, related} =
    Contacts.create_contact(admin.account_id, %{first_name: "Related", last_name: "Seed"})

  relationship_type =
    Repo.one!(
      from(t in Kith.Contacts.RelationshipType,
        where: is_nil(t.account_id) and t.system_key == "friend"
      )
    )

  {:ok, _} =
    Contacts.create_relationship(seed, %{
      related_contact_id: related.id,
      relationship_type_id: relationship_type.id
    })

  # Client NOTE has its own document provenance, separate from private description.
  {:ok, _} =
    Store.transaction(admin.account_id, fn ->
      current = Repo.reload!(seed) |> Repo.preload(Contacts.dav_preloads(), force: true)

      raw =
        VCardAdapter.contact_to_vcard(current, preloaded: true)
        |> String.replace("END:VCARD", "NOTE:Client-only seed note\r\nEND:VCARD")

      document = Kith.DAV.Document.accept(current, raw)
      current.dav |> Ecto.Changeset.change(document: document) |> Repo.update!()
      Store.touch(admin.account_id, [seed.id])
    end)

  for {name, hidden} <- [{"Archived", :archive_contact}, {"Trashed", :soft_delete_contact}] do
    {:ok, contact} =
      Contacts.create_contact(admin.account_id, %{first_name: name, last_name: "Seed"})

    {:ok, _} = apply(Contacts, hidden, [contact])
  end
end

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
  # app's insert paths, so it also exercises explicit DAV revision updates.
  email_type = FieldRegistry.canonical_type!(:emails)
  phone_type = FieldRegistry.canonical_type!(:phones)

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
    {:ok, _} =
      Store.transaction(account_id, fn ->
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
      end)
  end

  elapsed = System.monotonic_time(:millisecond) - started

  IO.puts(
    "==> carddav seed: perf account has #{perf_count} contacts (#{map_size(existing)} already there, #{elapsed} ms)"
  )
end

IO.puts("==> carddav seed: users ready")
