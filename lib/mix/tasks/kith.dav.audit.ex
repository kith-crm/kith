defmodule Mix.Tasks.Kith.Dav.Audit do
  @shortdoc "Audit DAV classification/duplicates; optionally backfill sanitized documents"
  @moduledoc """
  `mix kith.dav.audit --account-id ID` reports identifiers only, without values.
  `--backfill` initializes sanitized documents synchronously under account locks.
  This never deduplicates fields, promotes quarantined extras, or changes identity.
  """
  use Mix.Task
  import Ecto.Query
  alias Kith.Accounts.Account
  alias Kith.DAV.Audit
  alias Kith.Repo

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [account_id: :integer, backfill: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("Use --account-id ID [--backfill]")
    Mix.Task.run("app.start")

    ids =
      case opts[:account_id] do
        nil -> Repo.all(from a in Account, select: a.id, order_by: a.id)
        id -> [id]
      end

    Enum.each(ids, fn id ->
      result =
        if opts[:backfill], do: Audit.backfill(id), else: Audit.report(id)

      Mix.shell().info(Jason.encode!(result))
    end)
  end
end
