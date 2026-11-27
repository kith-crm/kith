defmodule Kith.Imports.Import do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending processing completed failed cancelled)

  schema "imports" do
    field :source, :string
    field :status, :string, default: "pending"
    field :file_name, :string
    field :file_size, :integer
    field :file_storage_key, :string
    field :api_url, :string
    field :api_key_encrypted, Kith.Vault.EncryptedBinary
    field :api_key_cleanup_eligible_at, :utc_datetime
    field :api_options, :map
    field :summary, :map
    field :sync_summary, :map
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :account, Kith.Accounts.Account
    belongs_to :user, Kith.Accounts.User

    has_many :import_records, Kith.Imports.ImportRecord

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def create_changeset(import, attrs) do
    import
    |> cast(attrs, [
      :source,
      :file_name,
      :file_size,
      :file_storage_key,
      :api_url,
      :api_key_encrypted,
      :api_options,
      :account_id,
      :user_id
    ])
    |> validate_required([:source, :account_id, :user_id])
    |> validate_inclusion(:source, ["monica_api", "vcard"])
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:account_id,
      name: :imports_one_active_per_account_idx,
      message: "an import is already in progress"
    )
  end

  def status_changeset(import, status, attrs \\ %{}) do
    import
    |> cast(attrs, [:summary, :started_at, :completed_at])
    |> put_change(:status, status)
    |> validate_inclusion(:status, @statuses)
  end
end
