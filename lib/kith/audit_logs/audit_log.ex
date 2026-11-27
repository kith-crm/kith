defmodule Kith.AuditLogs.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_events ~w(
    contact_created contact_updated contact_archived contact_restored
    contact_deleted contact_purged contact_merged
    reminder_fired
    user_joined user_role_changed user_removed
    invitation_sent invitation_accepted
    account_data_reset account_deleted optional_feature_changed
    immich_linked immich_unlinked
    data_exported data_imported
    trash_emptied
  )

  schema "audit_logs" do
    field :user_id, :integer
    field :user_name, :string
    field :contact_id, :integer
    field :contact_name, :string
    field :event, :string
    field :metadata, :map, default: %{}

    belongs_to :account, Kith.Accounts.Account

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def valid_events, do: @valid_events

  def create_changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :user_id,
      :user_name,
      :contact_id,
      :contact_name,
      :event,
      :metadata,
      :account_id
    ])
    |> validate_required([:event, :user_name, :account_id])
    |> validate_inclusion(:event, @valid_events)
    |> foreign_key_constraint(:account_id)
  end
end
