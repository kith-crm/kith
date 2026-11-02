defmodule Kith.Emails.ReminderAvatarTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Kith.AvatarFixtures
  import Kith.ReminderEmailFixtures
  import Swoosh.TestAssertions

  alias Kith.Contacts.{Avatar, AvatarAsset}
  alias Kith.Emails.ReminderNotification
  alias Kith.Storage
  alias Kith.Workers.ReminderEmailWorker

  setup do
    ctx = setup_fixture()
    {photo, _original} = stored_photo(ctx.contact)
    {:ok, contact} = Kith.Contacts.set_avatar(ctx.contact, photo)
    instance = Repo.preload(ctx.instance, [:account, reminder: :contact])
    {:ok, bytes} = Storage.read(contact.avatar)
    Map.merge(ctx, %{contact: contact, instance: instance, bytes: bytes})
  end

  defp build(ctx), do: ReminderNotification.build(ctx.user, ctx.instance)

  defp selected(ctx, key) do
    put_in(
      ctx,
      [:instance, Access.key(:reminder), Access.key(:contact), Access.key(:avatar)],
      key
    )
  end

  defp assert_initials(email) do
    assert length(email.attachments) == 1
    refute email.html_body =~ "cid:contact-avatar.jpg"
    assert email.html_body =~ "MV"
  end

  test "processed registered bytes resolve every CID, display at 46px and preserve text", ctx do
    email = build(ctx)
    fallback = build(selected(ctx, nil))
    assert email.text_body == fallback.text_body
    assert email.subject == fallback.subject
    assert email.to == fallback.to
    assert email.html_body =~ ~s(width="46" height="46")
    assert email.html_body =~ ~s(alt="MV")
    assert length(email.attachments) == 2

    for [_, cid] <- Regex.scan(~r/src="cid:([^"]+)"/, email.html_body) do
      assert Enum.count(email.attachments, &(&1.cid == cid and &1.type == :inline)) == 1
    end

    attachment = Enum.find(email.attachments, &(&1.cid == "contact-avatar.jpg"))
    assert attachment.data == ctx.bytes
    assert attachment.content_type == "image/jpeg"
    refute email.html_body =~ "/uploads/"
    refute email.html_body =~ ctx.contact.avatar
  end

  test "worker delivers the inline avatar only to the creator", ctx do
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id})

    assert_email_sent(fn email ->
      assert email.to == [{ctx.user.email, ctx.user.email}]
      assert length(email.attachments) == 2
      assert email.html_body =~ "cid:contact-avatar.jpg"
    end)
  end

  test "nil and unregistered legacy storage keys stay initials", ctx do
    legacy = Storage.generate_key(ctx.user.account_id, "photos", "legacy.jpg")
    {:ok, _} = Storage.upload_binary(ctx.bytes, legacy)
    for key <- [nil, legacy], do: assert_initials(build(selected(ctx, key)))
  end

  test "foreign asset registration and mismatched account chains stay initials", ctx do
    other = Kith.AccountsFixtures.user_fixture()

    Repo.get!(AvatarAsset, ctx.contact.avatar)
    |> Ecto.Changeset.change(account_id: other.account_id)
    |> Repo.update!()

    assert_initials(build(ctx))

    Repo.get!(AvatarAsset, ctx.contact.avatar)
    |> Ecto.Changeset.change(account_id: ctx.user.account_id)
    |> Repo.update!()

    assert length(build(ctx).attachments) == 2

    for path <- [
          [:user, Access.key(:account_id)],
          [:instance, Access.key(:account_id)],
          [:instance, Access.key(:account), Access.key(:id)],
          [:instance, Access.key(:reminder), Access.key(:account_id)],
          [:instance, Access.key(:reminder), Access.key(:contact), Access.key(:account_id)]
        ] do
      assert_initials(build(put_in(ctx, path, other.account_id)))
    end
  end

  test "missing files and storage read errors keep delivery working", ctx do
    :ok = Storage.delete(ctx.contact.avatar)
    assert_initials(build(ctx))
    File.mkdir_p!(Storage.Local.full_path(ctx.contact.avatar))
    on_exit(fn -> File.rmdir(Storage.Local.full_path(ctx.contact.avatar)) end)
    assert_initials(build(ctx))
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id})
    assert_email_sent(fn email -> assert_initials(email) end)
  end

  test "storage exceptions fall back without failing delivery", ctx do
    config = Application.get_env(:kith, Storage)
    on_exit(fn -> Application.put_env(:kith, Storage, config) end)
    Application.put_env(:kith, Storage, backend: :invalid)
    assert :ok = perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id})
    assert_email_sent(fn email -> assert_initials(email) end)
  end

  test "changed bytes, mismatched metadata and registered corrupt or unsupported bytes stay initials",
       ctx do
    asset = Repo.get!(AvatarAsset, ctx.contact.avatar)

    for bytes <- [
          "corrupt JPEG",
          <<255, 216, 255, 0>>,
          image_binary(width: 32, height: 32),
          image_binary(width: 600, height: 600, suffix: ".jpg"),
          image_binary(width: 64, height: 32, suffix: ".jpg")
        ] do
      {:ok, _} = Storage.upload_binary(bytes, ctx.contact.avatar)
      assert_initials(build(ctx))

      asset
      |> Ecto.Changeset.change(byte_size: byte_size(bytes), content_hash: Avatar.hash(bytes))
      |> Repo.update!()

      assert_initials(build(ctx))
    end

    {:ok, _} = Storage.upload_binary(ctx.bytes, ctx.contact.avatar)

    asset
    |> Ecto.Changeset.change(
      byte_size: byte_size(ctx.bytes) + 1,
      content_hash: Avatar.hash(ctx.bytes)
    )
    |> Repo.update!()

    assert_initials(build(ctx))
  end
end
