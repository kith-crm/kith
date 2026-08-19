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

    # First-met metadata
    field :middle_name, :string
    field :first_met_at, :date
    field :first_met_year_unknown, :boolean, default: false
    field :first_met_where, :string
    field :first_met_additional_info, :string
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
      :birthdate_year_unknown
    ])
    |> validate_required([:first_name, :account_id])
    |> assoc_constraint(:account)
    |> compute_display_name()
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
      :birthdate_year_unknown
    ])
    |> validate_required([:first_name])
    |> compute_display_name()
    |> validate_first_met_through_account()
  end

  def soft_delete_changeset(contact) do
    change(contact, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  def restore_changeset(contact) do
    change(contact, deleted_at: nil)
  end

  def archive_changeset(contact, archived?) do
    change(contact, is_archived: archived?)
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
