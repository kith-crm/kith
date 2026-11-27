defmodule Kith.Repo.Migrations.DropUserIdentities do
  use Ecto.Migration

  def up, do: drop(table(:user_identities))
end
