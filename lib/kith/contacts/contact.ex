defmodule Kith.Contacts.Contact do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Flop.Schema,
           filterable: [],
           sortable: [:display_name, :inserted_at, :last_talked_to],
           default_order: %{order_by: [:display_name], order_directions: [:asc]},
           default_limit: 20,
           max_limit: 100}

  @type t :: %__MODULE__{}

  schema "contacts" do
    field :first_name, :string
    field :last_name, :string
    field :display_name, :string
    field :nickname, :string
    field :birthdate, :date
    field :description, :string
    field :avatar, :string
    field :occupation, :string
    field :company, :string
    field :favorite, :boolean, default: false
    field :is_archived, :boolean, default: false
    field :deceased, :boolean, default: false
    field :deceased_at, :date
    field :last_talked_to, :utc_datetime
    field :deleted_at, :utc_datetime
    field :immich_person_id, :string
    field :immich_person_url, :string
    field :immich_status, :string, default: "unlinked"
    field :immich_last_synced_at, :utc_datetime
    field :aliases, {:array, :string}, default: []

    # R2: client-chosen CardDAV resource name and vCard UID (nil = kith defaults).
    # The name can also be set by a DB trigger at insert (R20), hence read back.
    field :dav_resource_name, :string, read_after_writes: true
    # Also set by the insert trigger when a client card holds this contact's
    # default UID (CDV-38), hence read back.
    field :dav_uid, :string, read_after_writes: true

    # R4: set by a DB trigger on every write of the row; the ETag derives from it
    field :dav_revision, :integer, read_after_writes: true
    # The client vCard retained for CardDAV round trips (up to ~1 MiB): not
    # loaded by plain queries, only by the DAV and vCard-export loaders
    # (`Kith.Contacts.load_dav_vcard/1`); nil means "not loaded" (CDV-119).
    field :dav_vcard, :map, load_in_query: false

    # First-met metadata
    field :middle_name, :string
    field :first_met_at, :date
    field :first_met_year_unknown, :boolean, default: false
    field :first_met_where, :string
    field :first_met_additional_info, :string
    field :first_met_reminder, :boolean, default: false
    field :birthdate_year_unknown, :boolean, default: false

    belongs_to :account, Kith.Accounts.Account
    belongs_to :gender, Kith.Contacts.Gender
    belongs_to :currency, Kith.Contacts.Currency
    belongs_to :first_met_through, Kith.Contacts.Contact

    has_many :addresses, Kith.Contacts.Address
    has_many :contact_fields, Kith.Contacts.ContactField
    has_many :notes, Kith.Contacts.Note
    has_many :documents, Kith.Contacts.Document
    has_many :photos, Kith.Contacts.Photo
    has_many :life_events, Kith.Activities.LifeEvent
    has_many :calls, Kith.Activities.Call
    has_many :reminders, Kith.Reminders.Reminder
    has_many :pets, Kith.Contacts.Pet
    has_many :tasks, Kith.Tasks.Task
    has_many :gifts, Kith.Contacts.Gift
    has_many :conversations, Kith.Conversations.Conversation
    has_many :debts, Kith.Contacts.Debt
    has_many :immich_candidates, Kith.Contacts.ImmichCandidate
    has_many :relationships, Kith.Contacts.Relationship

    many_to_many :tags, Kith.Contacts.Tag, join_through: "contact_tags"
    many_to_many :activities, Kith.Activities.Activity, join_through: "activity_contacts"

    field :avatar_data, :map, virtual: true

    timestamps(type: :utc_datetime)
  end

  def create_changeset(contact, attrs) do
    contact
    |> cast(attrs, [
      :first_name,
      :last_name,
      :nickname,
      :birthdate,
      :description,
      :avatar,
      :occupation,
      :company,
      :favorite,
      :is_archived,
      :deceased,
      :deceased_at,
      :last_talked_to,
      :immich_person_id,
      :immich_person_url,
      :immich_status,
      :immich_last_synced_at,
      :aliases,
      :account_id,
      :gender_id,
      :currency_id,
      :middle_name,
      :first_met_at,
      :first_met_year_unknown,
      :first_met_where,
      :first_met_through_id,
      :first_met_additional_info,
      :first_met_reminder,
      :birthdate_year_unknown
    ])
    |> validate_required([:first_name, :account_id])
    |> assoc_constraint(:account)
    |> compute_display_name()
    |> validate_column_lengths()
    |> validate_first_met_through_account()
  end

  def update_changeset(contact, attrs) do
    contact
    |> cast(attrs, [
      :first_name,
      :last_name,
      :nickname,
      :birthdate,
      :description,
      :avatar,
      :occupation,
      :company,
      :favorite,
      :is_archived,
      :deceased,
      :deceased_at,
      :last_talked_to,
      :gender_id,
      :currency_id,
      :immich_person_id,
      :immich_person_url,
      :immich_status,
      :immich_last_synced_at,
      :aliases,
      :middle_name,
      :first_met_at,
      :first_met_year_unknown,
      :first_met_where,
      :first_met_through_id,
      :first_met_additional_info,
      :first_met_reminder,
      :birthdate_year_unknown
    ])
    |> validate_required([:first_name])
    |> compute_display_name()
    |> validate_column_lengths()
    |> validate_first_met_through_account()
  end

  @doc "Sets the CardDAV resource name and vCard UID a client chose (R2)."
  def dav_changeset(contact, attrs) do
    contact
    |> cast(attrs, [:dav_resource_name, :dav_uid])
    |> unique_constraint(:dav_resource_name, name: :contacts_account_id_dav_resource_name_index)
    |> unique_dav_uid()
  end

  # At most one visible contact per stored vCard UID (CDV-36)
  defp unique_dav_uid(changeset),
    do: unique_constraint(changeset, :dav_uid, name: :contacts_account_id_dav_uid_index)

  def soft_delete_changeset(contact) do
    change(contact, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  def restore_changeset(contact) do
    contact |> change(deleted_at: nil) |> unique_dav_uid()
  end

  def archive_changeset(contact, archived?) do
    contact |> change(is_archived: archived?) |> unique_dav_uid()
  end

  defp validate_first_met_through_account(changeset) do
    with {_, through_id} when not is_nil(through_id) <-
           {:change, get_change(changeset, :first_met_through_id)},
         account_id when not is_nil(account_id) <- get_field(changeset, :account_id) do
      validate_through_contact(changeset, through_id, account_id)
    else
      {:change, nil} -> changeset
      _ -> changeset
    end
  end

  defp validate_through_contact(changeset, through_id, account_id) do
    contact_id = get_field(changeset, :id)

    cond do
      contact_id && through_id == contact_id ->
        add_error(changeset, :first_met_through_id, "cannot reference the contact itself")

      match?(%{account_id: ^account_id}, Kith.Repo.get(Kith.Contacts.Contact, through_id)) ->
        changeset

      true ->
        add_error(changeset, :first_met_through_id, "must be a contact in the same account")
    end
  end

  # varchar(255) columns: an over-long value is a changeset error, not a
  # Postgres exception (CDV-21)
  @varchar_fields [
    :first_name,
    :last_name,
    :middle_name,
    :display_name,
    :nickname,
    :occupation,
    :company,
    :first_met_where
  ]

  defp validate_column_lengths(changeset) do
    Enum.reduce(@varchar_fields, changeset, fn field, cs ->
      validate_length(cs, field, max: 255, count: :codepoints)
    end)
  end

  defp compute_display_name(changeset) do
    first = get_field(changeset, :first_name)
    middle = get_field(changeset, :middle_name)
    last = get_field(changeset, :last_name)

    display_name =
      [first, middle, last]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(" ")

    put_change(changeset, :display_name, display_name)
  end
end
