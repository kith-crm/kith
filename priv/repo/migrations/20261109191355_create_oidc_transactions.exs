defmodule Kith.Repo.Migrations.CreateOidcTransactions do
  use Ecto.Migration

  def change do
    create table(:oidc_transactions) do
      add :state_hash, :binary, null: false
      add :binding_hash, :binary, null: false
      add :issuer, :text, null: false
      add :intent, :string, null: false
      add :payload, :binary, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :initiated_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
    end

    create unique_index(:oidc_transactions, [:state_hash])
    create index(:oidc_transactions, [:expires_at])
    create index(:oidc_transactions, [:user_id])
  end
end
