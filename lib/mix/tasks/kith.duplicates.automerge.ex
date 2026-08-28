defmodule Mix.Tasks.Kith.Duplicates.Automerge do
  @shortdoc "Auto-merges detector-confident duplicate clusters for one account (issue #2)"

  @moduledoc """
  Runs the Monica-import auto-merge *second pass*
  (`Kith.Imports.DuplicateAutomerge`) standalone against an existing account,
  so a prod account that still has "100%" duplicate clusters can be cleaned
  without re-importing.

  It runs a fresh `Kith.DuplicateDetection.scan_account/1`, then over the
  account's `pending` `DuplicateCandidate` graph it merges every connected
  component in which **every** candidate edge is a *strong* edge: it scores
  `>= --min-score` (default `1.0`) **and** carries at least one concrete
  signal — `email_match`, `phone_match`, or `address_match`.

  A **name-only** pair (`reasons == ["name_match"]`) is never auto-merged,
  even at score `1.0` and even with `--min-score` lowered — identical first
  and last names for different people are common. Such pairs stay as pending
  `DuplicateCandidate`s for manual review.

  A contact attached to a merge target only through a non-strong edge (a
  sub-floor score, or a name-only match at any score) is left unmerged and
  logged — reported as `left_behind`. A component is skipped (reported as
  `skipped`) when two of its members carry different non-empty birthdates.

  This task is **account-wide** — there is no `--restrict` option. Unlike the
  importer's own second pass, which is scoped to the contacts a single import
  run inserted, this considers every pending candidate in the account.

  Scope-safe (one account only) and idempotent.

  ## Usage

      mix kith.duplicates.automerge --account 123
      mix kith.duplicates.automerge --account 123 --dry-run
      mix kith.duplicates.automerge --account 123 --min-score 1.0
  """

  use Mix.Task

  alias Kith.Imports.DuplicateAutomerge

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [account: :integer, dry_run: :boolean, min_score: :float]
      )

    account_id = opts[:account] || Mix.raise("--account <id> is required")
    dry_run = Keyword.get(opts, :dry_run, false)
    min_score = Keyword.get(opts, :min_score, 1.0)

    Mix.Task.run("app.start")

    result = DuplicateAutomerge.run(account_id, dry_run: dry_run, min_score: min_score)

    Mix.shell().info(
      "account=#{account_id} dry_run=#{dry_run} min_score=#{min_score} " <>
        "merged=#{result.merged} clusters_merged=#{result.clusters_merged} " <>
        "skipped=#{result.skipped} left_behind=#{result.left_behind} " <>
        "errors=#{length(result.errors)}"
    )

    Enum.each(result.errors, &Mix.shell().info("  error: #{&1}"))
  end
end
