defmodule Kith.Repo.Migrations.CreateAuthChallenges do
  use Ecto.Migration

  def change do
    alter table(:user_tokens) do
      add :mfa_authenticated_at, :utc_datetime
    end

    create table(:auth_challenges) do
      add :handle_hash, :binary, null: false
      add :binding_hash, :binary, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :intent, :string, null: false
      add :authenticated_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :payload, :binary, null: false
    end

    create unique_index(:auth_challenges, [:handle_hash])
    create index(:auth_challenges, [:expires_at])
    create index(:auth_challenges, [:user_id])
  end
end
