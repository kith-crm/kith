defmodule Kith.Cache.Invalidation do
  @moduledoc """
  Invalidates DB-derived cache keys after successful context mutations commit.

  A context called inside an existing transaction cannot observe its outer
  commit. The owner must call `after_commit/2` after its `Repo.transaction/1`
  returns; nested contexts intentionally do nothing. This is an explicit
  context-boundary contract, not an Ecto commit hook. DB-derived reads bypass
  shared caching inside transactions so uncommitted values are never published.
  """

  def after_commit(result, keys) do
    if (result == :ok or match?({:ok, _}, result)) and not Kith.Repo.in_transaction?() do
      Enum.each(List.wrap(keys), &Kith.Cache.delete/1)
    end

    result
  end
end
