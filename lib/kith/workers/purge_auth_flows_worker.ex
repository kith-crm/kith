defmodule Kith.Workers.PurgeAuthFlowsWorker do
  @moduledoc "Purges expired browser transactions; expiry is also enforced on consumption."
  use Oban.Worker, queue: :purge
  import Ecto.Query
  alias Kith.Auth.OIDC.Transaction
  alias Kith.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    Repo.delete_all(from(f in Transaction, where: f.expires_at <= ^now))
    Repo.delete_all(from(f in Kith.Auth.Challenge, where: f.expires_at <= ^now))
    :ok
  end
end
