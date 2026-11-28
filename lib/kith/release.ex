defmodule Kith.Release do
  @moduledoc """
  Release tasks for running migrations and other admin operations
  outside of Mix (i.e., from a compiled release in production).

  Used by the `migrate` Docker service (KITH_MODE=migrate).
  """

  @app :kith

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    path = Application.app_dir(@app, "priv/repo/data_migrations")
    {:ok, _, _} =
      Ecto.Migrator.with_repo(
        Kith.Repo,
        &Ecto.Migrator.run(&1, path, :up, all: true)
      )
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
