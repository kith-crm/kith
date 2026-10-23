# Isolated live-client actions. Invoke with the harness environment sourced.
import Ecto.Query
alias Kith.{Contacts, Repo}
alias Kith.Contacts.Contact
alias Kith.DAV.ContactDav

unless Repo.config()[:database] == "kith_carddav_task10_e2e", do: raise("isolated DB required")
[action, email | args] = System.argv()
user = Repo.get_by!(Kith.Accounts.User, email: email)

if action == "empty-trash" do
  {:ok, _} = Contacts.empty_trash(user.account_id)
else
  [uid] = args

  contact =
    Repo.one!(
      from c in Contact,
        join: d in ContactDav,
        on: d.contact_id == c.id,
        where: c.account_id == ^user.account_id and d.uid == ^uid,
        select: c
    )

  case action do
    "edit" ->
      field =
        Contacts.list_contact_fields(contact.id)
        |> Enum.find(&String.starts_with?(&1.value, "+1555"))

      {:ok, _} = Contacts.update_contact_field(field, %{value: "+15550999999"})
      {:ok, tag} = Contacts.create_tag(user.account_id, %{name: "CLI tag #{uid}"})
      {1, _} = Contacts.tag_contact(contact, tag)
      {:ok, _} = Contacts.update_tag(tag, %{name: "Renamed CLI tag #{uid}"})

    "trash" ->
      {:ok, _} = Contacts.soft_delete_contact(contact)

    "archive" ->
      {:ok, _} = Contacts.archive_contact(contact)

    "restore" ->
      {:ok, _} = Contacts.restore_contact(contact)

    "assert-trash" ->
      if is_nil(contact.deleted_at), do: raise("contact is not trashed")
  end
end

IO.puts("PASS application action #{action}")
