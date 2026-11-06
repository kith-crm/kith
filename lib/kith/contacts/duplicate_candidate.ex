defmodule Kith.Contacts.DuplicateCandidate do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending merged dismissed)

  @type t :: %__MODULE__{}

  schema "duplicate_candidates" do
    field :score, :float
    field :reasons, {:array, :string}, default: []
    field :status, :string, default: "pending"
    field :detected_at, :utc_datetime
    field :resolved_at, :utc_datetime

    belongs_to :account, Kith.Accounts.Account
    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :duplicate_contact, Kith.Contacts.Contact

    timestamps(type: :utc_datetime)
  end

  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, [
      :score,
      :reasons,
      :status,
      :detected_at,
      :resolved_at,
      :contact_id,
      :duplicate_contact_id
    ])
    |> validate_required([:score, :detected_at, :contact_id, :duplicate_contact_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:contact_id)
    |> foreign_key_constraint(:duplicate_contact_id)
    |> unique_constraint([:account_id, :contact_id, :duplicate_contact_id])
    |> check_constraint(:contact_id,
      name: :contact_id_ordering,
      message: "contact_id must be less than duplicate_contact_id"
    )
  end

  def dismiss_changeset(candidate) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(candidate, status: "dismissed", resolved_at: now)
  end
end
