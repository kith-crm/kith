defmodule Mix.Tasks.Kith.Duplicates.Automerge do
  @shortdoc "Auto-merges detector-confident duplicate clusters for one account (issue #2)"

  @moduledoc """
  Runs the Monica-import auto-merge *second pass*
  (`Kith.Imports.DuplicateAutomerge`) standalone against an existing account,
  so a prod account that still has "100%" duplicate clusters can be cleaned
  without re-importing.

  It runs a fresh `Kith.DuplicateDetection.scan_account/1`, clusters the
  resulting `pending` candidates, and merges every cluster that carries a
  pair scoring `>= --min-score` (default `1.0`), skipping clusters where a
  pair rests only on a fuzzy name match or where members disagree on a
  non-empty birthdate.

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
        "skipped=#{result.skipped} errors=#{length(result.errors)}"
    )

    Enum.each(result.errors, &Mix.shell().info("  error: #{&1}"))
  end
end
