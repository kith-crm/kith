defmodule Kith.Repo.Migrations.CreateDavAppPasswords do
  use Ecto.Migration

  def change do
    create table(:dav_app_passwords) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, size: 80, null: false
      add :public_id, :string, size: 22, null: false
      add :secret_hash, :binary, null: false
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:dav_app_passwords, [:public_id])
    create index(:dav_app_passwords, [:user_id])
  end
end
