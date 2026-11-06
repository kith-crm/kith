defmodule Kith.Repo.Migrations.AddAvatarCropMetadata do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :avatar_crop, :map
    end
  end
end
