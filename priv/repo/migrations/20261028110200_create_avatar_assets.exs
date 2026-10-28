defmodule Kith.Repo.Migrations.CreateAvatarAssets do
  use Ecto.Migration

  def up do
    create table(:avatar_assets, primary_key: false) do
      add :storage_key, :text, primary_key: true
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :byte_size, :integer, null: false
      add :content_hash, :string, null: false
    end

    create index(:avatar_assets, [:account_id])

    execute """
    INSERT INTO avatar_assets (storage_key, account_id, byte_size, content_hash)
    SELECT DISTINCT ON (avatar_storage_key)
      avatar_storage_key, account_id, avatar_file_size, avatar_content_hash
    FROM photos
    WHERE avatar_storage_key IS NOT NULL
      AND avatar_file_size IS NOT NULL
      AND avatar_content_hash IS NOT NULL
    ORDER BY avatar_storage_key, id
    """
  end

  def down do
    drop table(:avatar_assets)
  end
end
