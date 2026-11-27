defmodule Kith.Repo.Migrations.CreateOIDCIdentities do
  use Ecto.Migration

  def change do
    create table(:oidc_identities) do
      add :issuer, :text, null: false
      add :subject, :text, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oidc_identities, [:issuer, :subject])
    create index(:oidc_identities, [:user_id])
  end
end
