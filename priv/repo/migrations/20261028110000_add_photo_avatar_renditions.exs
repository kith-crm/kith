defmodule Kith.Repo.Migrations.AddPhotoAvatarRenditions do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :avatar_storage_key, :text
      add :avatar_file_size, :integer
      add :avatar_signature, :string
      add :avatar_content_hash, :string
    end

    create index(:photos, [:account_id, :avatar_storage_key])
  end
end
