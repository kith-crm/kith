defmodule Kith.Repo.Migrations.AllowUnknownAuthenticationTime do
  use Ecto.Migration

  def up, do: execute("ALTER TABLE auth_challenges ALTER COLUMN authenticated_at DROP NOT NULL")

  def down do
    # Roll back after outstanding challenges have expired and the purge job has run.
    execute("ALTER TABLE auth_challenges ALTER COLUMN authenticated_at SET NOT NULL")
  end
end
