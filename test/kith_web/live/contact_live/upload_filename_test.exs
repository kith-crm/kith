defmodule KithWeb.ContactLive.UploadFilenameTest do
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kith.ContactsFixtures

  alias Kith.{Contacts, Storage}

  defmodule ComponentsHost do
    use KithWeb, :live_view

    def mount(_params, %{"contact_id" => id, "account_id" => account_id}, socket) do
      contact = Kith.Contacts.get_contact!(account_id, id)
      {:ok, assign(socket, contact: contact)}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={KithWeb.ContactLive.DocumentsListComponent}
        id="documents"
        contact_id={@contact.id}
        account_id={@contact.account_id}
        can_edit={true}
      />
      <.live_component
        module={KithWeb.ContactLive.PhotosGalleryComponent}
        id="photos"
        contact={@contact}
        can_edit={true}
      />
      """
    end
  end

  setup :register_and_log_in_user

  setup %{user: user} do
    root = Path.join(System.tmp_dir!(), "kith-upload-names-#{Ecto.UUID.generate()}")
    Kith.TestEnv.put_env_restoring(:kith, Storage, backend: :local, path: root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{contact: contact_fixture(user.account_id), root: root}
  end

  test "document and gallery uploads preserve percent and traversal-like display names", ctx do
    {:ok, view, _} =
      live_isolated(ctx.conn, ComponentsHost,
        session: %{"contact_id" => ctx.contact.id, "account_id" => ctx.contact.account_id}
      )

    upload(
      view,
      "#doc-upload-#{ctx.contact.id}",
      :document,
      "100% complete.pdf",
      "application/pdf",
      "report contents"
    )

    upload(
      view,
      "#photo-upload-#{ctx.contact.id}",
      :photo,
      "../../100% complete.png",
      "image/png",
      "photo contents"
    )

    [document] = Contacts.list_documents(ctx.contact.id)
    [photo] = Contacts.list_photos(ctx.contact.id)
    assert document.file_name == "100% complete.pdf"
    assert photo.file_name == "../../100% complete.png"
    assert_safe_file(document, ctx, "documents", ".pdf", "report contents")
    assert_safe_file(photo, ctx, "photos", ".png", "photo contents")
    stop_view(view)
  end

  test "timeline and avatar uploads use generated keys", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/contacts/#{ctx.contact.id}")

    view
    |> element(~s|button[phx-click="open-entry-modal"][phx-value-type="photo"]|)
    |> render_click()

    upload(view, "#photo-upload-form", :photo, "100% memories.png", "image/png", "timeline photo")
    view |> element(~s|button[phx-click="toggle-avatar-picker"]|) |> render_click()

    upload(
      view,
      ~s|form[phx-submit="upload-avatar"]|,
      :avatar,
      "../100% portrait.png",
      "image/png",
      "avatar photo"
    )

    photos = Contacts.list_photos(ctx.contact.id)

    assert MapSet.new(Enum.map(photos, & &1.file_name)) ==
             MapSet.new(["100% memories.png", "../100% portrait.png"])

    for photo <- photos do
      contents =
        if photo.file_name == "100% memories.png", do: "timeline photo", else: "avatar photo"

      assert_safe_file(photo, ctx, "photos", ".png", contents)
    end

    updated = Contacts.get_contact!(ctx.contact.account_id, ctx.contact.id)

    assert Enum.find(photos, &(&1.storage_key == updated.avatar)).file_name ==
             "../100% portrait.png"

    stop_view(view)
  end

  test "storage failure is reported and creates no document or photo", ctx do
    File.mkdir_p!(ctx.root)
    File.write!(Path.join(ctx.root, "blocked"), "a regular file")

    Kith.TestEnv.put_env_restoring(:kith, Storage,
      backend: :local,
      path: Path.join(ctx.root, "blocked")
    )

    {:ok, view, _} =
      live_isolated(ctx.conn, ComponentsHost,
        session: %{"contact_id" => ctx.contact.id, "account_id" => ctx.contact.account_id}
      )

    upload(
      view,
      "#doc-upload-#{ctx.contact.id}",
      :document,
      "100% complete.pdf",
      "application/pdf",
      "report"
    )

    upload(
      view,
      "#photo-upload-#{ctx.contact.id}",
      :photo,
      "100% complete.png",
      "image/png",
      "photo"
    )

    assert render(view) =~ "Some documents could not be uploaded"
    assert render(view) =~ "Some photos could not be uploaded"
    assert Contacts.list_documents(ctx.contact.id) == []
    assert Contacts.list_photos(ctx.contact.id) == []
    assert Process.alive?(view.pid)
    stop_view(view)

    {:ok, view, _} = live(ctx.conn, ~p"/contacts/#{ctx.contact.id}")

    view
    |> element(~s|button[phx-click="open-entry-modal"][phx-value-type="photo"]|)
    |> render_click()

    upload(view, "#photo-upload-form", :photo, "100% timeline.png", "image/png", "timeline")
    assert render(view) =~ "Some photos could not be uploaded"
    view |> element(~s|button[phx-click="toggle-avatar-picker"]|) |> render_click()

    upload(
      view,
      ~s|form[phx-submit="upload-avatar"]|,
      :avatar,
      "100% avatar.png",
      "image/png",
      "avatar"
    )

    assert render(view) =~ "Avatar could not be uploaded"
    assert Contacts.list_photos(ctx.contact.id) == []
    assert Contacts.get_contact!(ctx.contact.account_id, ctx.contact.id).avatar == nil
    stop_view(view)
  end

  defp upload(view, selector, name, filename, type, contents) do
    input = file_input(view, selector, name, [%{name: filename, content: contents, type: type}])
    render_upload(input, filename)
    view |> form(selector) |> render_submit()
  end

  defp assert_safe_file(record, ctx, type, ext, contents) do
    assert record.account_id == ctx.contact.account_id
    assert record.contact_id == ctx.contact.id

    assert record.storage_key =~
             ~r/\A#{ctx.contact.account_id}\/[a-z]+\/[0-9a-f-]{36}#{Regex.escape(ext)}\z/

    assert String.split(record.storage_key, "/") |> Enum.at(1) == type
    refute record.storage_key =~ "%"
    refute record.storage_key =~ ".."
    assert Storage.read(record.storage_key) == {:ok, contents}
    assert File.read!(Path.join(ctx.root, record.storage_key)) == contents
  end

  defp stop_view(view) do
    render(view)
    GenServer.stop(view.pid, :normal)
  end
end
