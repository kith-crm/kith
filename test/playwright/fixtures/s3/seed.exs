# Seeds one confirmed user with: a contact whose photo file is missing, a
# contact whose photo is still syncing, two duplicates with different avatars
# (one missing), for test/playwright/image-fallback.spec.ts. Requires the
# fake S3 (fake_s3.py) and REVIEW_S3=1 dev config (see README).
# Also uploads two valid PNGs (ok-1.png, avatar-a.png) to the fake S3.
alias Kith.{Accounts, Contacts, Repo}

email = "img-#{System.unique_integer([:positive])}@test.local"
{:ok, user} = Accounts.register_user(%{email: email, password: "ValidP@ssword123!"})
user = user |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second)) |> Repo.update!()
acc = user.account_id

png =
  Base.decode64!(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

{:ok, _} = Kith.Storage.upload_binary(png, "#{acc}/photos/ok-1.png")
{:ok, _} = Kith.Storage.upload_binary(png, "#{acc}/avatars/avatar-a.png")

{:ok, photo_contact} = Contacts.create_contact(acc, %{first_name: "Photo", last_name: "Missing"})

photo = fn contact, key, name ->
  %Contacts.Photo{}
  |> Contacts.Photo.changeset(%{
    file_name: name,
    storage_key: key,
    file_size: 100,
    content_type: "image/png",
    contact_id: contact.id,
    account_id: acc
  })
  |> Repo.insert!()
end

missing = photo.(photo_contact, "#{acc}/photos/missing-1.png", "p.png")
syncing = photo.(photo_contact, "pending_sync:immich-1", "p.png")

# Dedicated contacts so parallel/mutating tests never share photos.
# tile_contact: one syncing, one loaded, one missing photo (timeline + tile variants).
# patch/stale/changed contacts: one missing photo each.
new_contact = fn name ->
  {:ok, c} = Contacts.create_contact(acc, %{first_name: name, last_name: "Photos"})
  c
end

tile_contact = new_contact.("Tile")
tile_missing = photo.(tile_contact, "#{acc}/photos/missing-t.png", "tile-missing.png")
tile_syncing = photo.(tile_contact, "pending_sync:immich-t", "tile-syncing.png")
tile_ok = photo.(tile_contact, "#{acc}/photos/ok-1.png", "tile-ok.png")

patch_contact = new_contact.("Patch")
patch_photo = photo.(patch_contact, "#{acc}/photos/missing-p.png", "patch-before.png")

stale_contact = new_contact.("Stale")
stale_photo = photo.(stale_contact, "#{acc}/photos/missing-s.png", "stale.png")

changed_contact = new_contact.("Changed")
changed_photo = photo.(changed_contact, "#{acc}/photos/missing-c.png", "changed.png")

{:ok, a} =
  Contacts.create_contact(acc, %{
    first_name: "Mona",
    last_name: "Vale",
    avatar: "#{acc}/avatars/avatar-a.png"
  })

{:ok, b} =
  Contacts.create_contact(acc, %{
    first_name: "Mona",
    last_name: "Vale",
    avatar: "#{acc}/avatars/missing-b.png"
  })

Repo.insert!(%Contacts.DuplicateCandidate{
  account_id: acc,
  contact_id: min(a.id, b.id),
  duplicate_contact_id: max(a.id, b.id),
  score: 1.0,
  reasons: ["name_match"],
  status: "pending",
  detected_at: DateTime.utc_now(:second)
})

IO.puts(
  Jason.encode!(%{
    email: email,
    password: "ValidP@ssword123!",
    photo_contact: photo_contact.id,
    missing_photo: missing.id,
    syncing_photo: syncing.id,
    a: a.id,
    b: b.id,
    ok_key: "#{acc}/photos/ok-1.png",
    tile_contact: tile_contact.id,
    tile_missing: tile_missing.id,
    tile_syncing: tile_syncing.id,
    tile_ok: tile_ok.id,
    patch_contact: patch_contact.id,
    patch_photo: patch_photo.id,
    stale_contact: stale_contact.id,
    stale_photo: stale_photo.id,
    changed_contact: changed_contact.id,
    changed_photo: changed_photo.id
  })
)
