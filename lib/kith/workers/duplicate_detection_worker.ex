defmodule Kith.Workers.DuplicateDetectionWorker do
  @moduledoc """
  Oban worker that detects potential duplicate contacts within an account.
  Runs weekly via cron or can be triggered manually per-account.

  The detection algorithm and scoring live in
  `Kith.DuplicateDetection.scan_account/1`; this worker only fans it out over
  one account (when given an `account_id`) or every account (cron).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  import Ecto.Query
  alias Kith.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    Kith.DuplicateDetection.scan_account(account_id)
    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    # Run for all accounts when triggered by cron (no account_id)
    account_ids =
      from(a in Kith.Accounts.Account, select: a.id)
      |> Repo.all()

    Enum.each(account_ids, &Kith.DuplicateDetection.scan_account/1)
    :ok
  end
end
