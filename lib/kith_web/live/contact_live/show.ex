defmodule KithWeb.ContactLive.Show do
  @moduledoc """
  Contact profile page with hero banner, grouped sidebar, and unified activity stream.
  """

  use KithWeb, :live_view

  alias Kith.AuditLogs
  alias Kith.Contacts
  alias Kith.Contacts.Avatar
  alias Kith.DAV.Store
  alias Kith.DuplicateDetection
  alias Kith.Repo
  alias Kith.Storage

  @impl true
  def mount(_params, _session, socket) do
    # No DB queries in mount — mount is called twice (HTTP + WebSocket).
    {:ok,
     socket
     |> assign(:contact, nil)
     |> assign(:tags, [])
     |> assign(:tag_search, "")
     |> assign(:show_tag_dropdown, false)
     |> assign(:show_more_drawer, false)
     |> assign(:mobile_sidebar_tab, "basic-info")
     |> assign(:duplicate_candidates, [])
     |> assign(:next_reminder, nil)
     |> assign(:show_avatar_picker, false)
     |> assign(:avatar_photos, [])
     |> assign(:avatar_crop, nil)
     |> allow_upload(:avatar,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 1,
       auto_upload: true,
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    account_id = socket.assigns.current_scope.account.id
    user_id = socket.assigns.current_scope.user.id

    contact =
      Contacts.get_contact!(account_id, String.to_integer(id))
      |> Kith.Repo.preload([:tags, :gender, :first_met_through])

    next_reminder = compute_next_birthday_badge(contact)

    {:noreply,
     socket
     |> assign(:page_title, contact.display_name)
     |> assign(:account_id, account_id)
     |> assign(:current_user_id, user_id)
     |> assign(:contact, contact)
     |> assign(:tags, Contacts.list_tags(account_id))
     |> assign(:next_reminder, next_reminder)
     |> assign(
       :duplicate_candidates,
       DuplicateDetection.pending_candidates_for_contact(account_id, contact.id)
     )}
  end

  @impl true
  def handle_event("toggle-favorite", _params, socket) do
    contact = socket.assigns.contact
    {:ok, updated} = Contacts.update_contact(contact, %{favorite: !contact.favorite})

    {:noreply,
     assign(socket, :contact, Kith.Repo.preload(updated, [:tags, :gender, :first_met_through]))}
  end

  def handle_event("archive", _params, socket) do
    contact = socket.assigns.contact
    user = socket.assigns.current_scope.user
    account_id = socket.assigns.account_id

    {:ok, updated} = Contacts.archive_contact(contact)

    AuditLogs.log_event(account_id, user, :contact_archived,
      contact_id: contact.id,
      contact_name: contact.display_name
    )

    {:noreply,
     socket
     |> assign(:contact, Kith.Repo.preload(updated, [:tags, :gender, :first_met_through]))
     |> put_flash(:info, "#{contact.display_name} archived.")}
  end

  def handle_event("unarchive", _params, socket) do
    contact = socket.assigns.contact
    user = socket.assigns.current_scope.user
    account_id = socket.assigns.account_id

    {:ok, updated} = Contacts.unarchive_contact(contact)

    AuditLogs.log_event(account_id, user, :contact_restored,
      contact_id: contact.id,
      contact_name: contact.display_name
    )

    {:noreply,
     socket
     |> assign(:contact, Kith.Repo.preload(updated, [:tags, :gender, :first_met_through]))
     |> put_flash(:info, "#{contact.display_name} unarchived.")}
  end

  def handle_event("delete", _params, socket) do
    contact = socket.assigns.contact
    user = socket.assigns.current_scope.user
    account_id = socket.assigns.account_id

    {:ok, _} = Contacts.soft_delete_contact(contact)

    AuditLogs.log_event(account_id, user, :contact_deleted,
      contact_id: contact.id,
      contact_name: contact.display_name
    )

    {:noreply,
     socket
     |> put_flash(:info, "#{contact.display_name} moved to trash.")
     |> push_navigate(to: ~p"/contacts")}
  end

  def handle_event("toggle-more-drawer", _params, socket) do
    {:noreply, update(socket, :show_more_drawer, &(!&1))}
  end

  def handle_event("switch-mobile-tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :mobile_sidebar_tab, tab)}
  end

  def handle_event("toggle-tag-dropdown", _params, socket) do
    {:noreply, update(socket, :show_tag_dropdown, &(!&1))}
  end

  def handle_event("search-tags", %{"tag_search" => query}, socket) do
    {:noreply, assign(socket, :tag_search, query)}
  end

  def handle_event("add-tag", %{"tag_id" => tag_id}, socket) do
    account_id = socket.assigns.account_id
    contact = socket.assigns.contact
    tag = Contacts.get_tag!(account_id, String.to_integer(tag_id))

    Contacts.tag_contact(contact, tag)

    updated_contact =
      Kith.Repo.preload(contact, [:tags, :gender, :first_met_through], force: true)

    {:noreply,
     socket
     |> assign(:contact, updated_contact)
     |> assign(:show_tag_dropdown, false)
     |> assign(:tag_search, "")}
  end

  def handle_event("toggle-avatar-picker", _params, socket) do
    show = !socket.assigns.show_avatar_picker
    photos = if show, do: Contacts.list_photos(socket.assigns.contact.id), else: []
    {:noreply, socket |> assign(:show_avatar_picker, show) |> assign(:avatar_photos, photos)}
  end

  def handle_event("pick-avatar-photo", %{"id" => id}, socket) do
    {:noreply, open_avatar_crop(socket, id)}
  end

  def handle_event("validate-avatar", _params, socket) do
    crop =
      case socket.assigns.uploads.avatar.entries do
        [%{valid?: true} = entry | _] -> {:upload, entry.ref}
        _ -> nil
      end

    {:noreply, assign(socket, :avatar_crop, crop)}
  end

  def handle_event("cancel-avatar-upload", %{"ref" => ref}, socket) do
    {:noreply, socket |> cancel_upload(:avatar, ref) |> assign(:avatar_crop, nil)}
  end

  def handle_event("cancel-avatar-crop", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.avatar.entries, socket, fn entry, socket ->
        cancel_upload(socket, :avatar, entry.ref)
      end)

    {:noreply, assign(socket, :avatar_crop, nil)}
  end

  def handle_event("upload-avatar", %{"crop" => crop}, socket) do
    if Kith.Policy.can?(socket.assigns.current_scope.user, :update, :contact) do
      socket |> save_avatar_crop(crop) |> avatar_crop_result(socket)
    else
      {:noreply, put_flash(socket, :error, "You cannot change this avatar.")}
    end
  end

  def handle_event("remove-tag", %{"tag_id" => tag_id}, socket) do
    account_id = socket.assigns.account_id
    contact = socket.assigns.contact
    tag = Contacts.get_tag!(account_id, String.to_integer(tag_id))

    Contacts.untag_contact(contact, tag)

    updated_contact =
      Kith.Repo.preload(contact, [:tags, :gender, :first_met_through], force: true)

    {:noreply, assign(socket, :contact, updated_contact)}
  end

  @impl true
  def handle_info({:crop_avatar, photo_id}, socket) do
    {:noreply, open_avatar_crop(socket, Integer.to_string(photo_id))}
  end

  def handle_info({:avatar_updated, updated_contact}, socket) do
    updated_contact =
      Kith.Repo.preload(updated_contact, [:tags, :gender, :first_met_through], force: true)

    {:noreply,
     socket
     |> assign(:contact, updated_contact)
     |> assign(:avatar_photos, Contacts.list_photos(updated_contact.id))}
  end

  def handle_info({:contact_updated, updated_contact}, socket) do
    contact =
      Kith.Repo.preload(updated_contact, [:tags, :gender, :first_met_through], force: true)

    {:noreply, assign(socket, :contact, contact)}
  end

  defp compute_age(birthdate) when is_struct(birthdate, Date) do
    today = Date.utc_today()
    years = today.year - birthdate.year

    if Date.compare(Kith.TimeHelper.anniversary_in_year(birthdate, today.year), today) == :gt do
      years - 1
    else
      years
    end
  end

  defp compute_age(_), do: nil

  defp can?(assigns, action, resource) do
    Kith.Policy.can?(assigns.current_scope.user, action, resource)
  end

  defp compute_next_birthday_badge(contact) do
    case contact.birthdate do
      nil ->
        nil

      birthdate ->
        today = Date.utc_today()
        this_year = Kith.TimeHelper.anniversary_in_year(birthdate, today.year)

        next_birthday =
          if Date.compare(this_year, today) in [:gt, :eq],
            do: this_year,
            else: Kith.TimeHelper.anniversary_in_year(birthdate, today.year + 1)

        days = Date.diff(next_birthday, today)

        label =
          cond do
            days == 0 -> "today"
            days == 1 -> "tomorrow"
            true -> "in #{days} days"
          end

        "Birthday #{label}"
    end
  end

  defp filtered_tags(tags, contact_tags, search) do
    contact_tag_ids = Enum.map(contact_tags, & &1.id) |> MapSet.new()

    tags
    |> Enum.reject(&MapSet.member?(contact_tag_ids, &1.id))
    |> then(fn tags ->
      if search == "" do
        tags
      else
        Enum.filter(tags, &String.contains?(String.downcase(&1.name), String.downcase(search)))
      end
    end)
  end

  defp open_avatar_crop(socket, id) do
    if Kith.Policy.can?(socket.assigns.current_scope.user, :update, :contact) do
      photo = Contacts.get_photo!(socket.assigns.account_id, String.to_integer(id))

      if photo.contact_id == socket.assigns.contact.id,
        do: assign(socket, :avatar_crop, {:photo, photo}),
        else: put_flash(socket, :error, "Photo not found.")
    else
      put_flash(socket, :error, "You cannot change this avatar.")
    end
  end

  defp save_avatar_crop(%{assigns: %{avatar_crop: {:photo, photo}}} = socket, crop) do
    Contacts.set_avatar(socket.assigns.contact, photo, crop: crop)
  end

  defp save_avatar_crop(%{assigns: %{avatar_crop: {:upload, _}}} = socket, crop) do
    results =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
        {:ok, save_uploaded_avatar(socket.assigns.contact, path, entry, crop)}
      end)

    case results do
      [result] -> result
      _ -> {:error, :upload_incomplete}
    end
  end

  defp save_avatar_crop(_socket, _crop), do: {:error, :missing_photo}

  defp save_uploaded_avatar(contact, path, entry, crop) do
    key = Storage.generate_key(contact.account_id, "photos", entry.client_name)

    Avatar.with_cleanup(fn ->
      Store.transaction(contact.account_id, fn ->
        insert_uploaded_avatar!(contact, path, entry, crop, key)
      end)
    end)
  end

  defp insert_uploaded_avatar!(contact, path, entry, crop, key) do
    with :ok <- Storage.check_storage_limit(contact.account_id, entry.client_size),
         {:ok, _} <- Storage.upload(path, key),
         :ok <- Avatar.stage_created(key),
         {:ok, photo} <-
           Contacts.create_photo(contact, %{
             file_name: entry.client_name,
             storage_key: key,
             file_size: entry.client_size,
             content_type: entry.client_type
           }),
         {:ok, updated} <- Contacts.set_avatar(contact, photo, crop: crop) do
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp avatar_crop_result({:ok, contact}, socket) do
    contact = Repo.preload(contact, [:tags, :gender, :first_met_through], force: true)

    {:noreply,
     socket
     |> assign(:contact, contact)
     |> assign(:avatar_crop, nil)
     |> assign(:show_avatar_picker, false)
     |> assign(:avatar_photos, Contacts.list_photos(contact.id))
     |> put_flash(:info, "Avatar updated.")}
  end

  defp avatar_crop_result({:error, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:avatar_crop, nil)
     |> put_flash(:error, "Could not save this avatar. Choose a valid image and try again.")}
  end

  defp avatar_upload_error(:too_large), do: "Choose an image smaller than 10 MB."
  defp avatar_upload_error(:not_accepted), do: "Choose a JPEG, PNG, GIF, or WebP image."
  defp avatar_upload_error(:too_many_files), do: "Choose one avatar image at a time."
  defp avatar_upload_error(_error), do: "This image could not be uploaded."
end
