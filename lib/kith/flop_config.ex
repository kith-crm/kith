defmodule Kith.FlopConfig do
  @moduledoc """
  Named Flop backend for Kith.

  Schemas use Flop.Schema and @flop_options to declare filterable/sortable fields.
  This module provides the named backend that can be passed to Flop
  functions when the global config isn't sufficient.

  ## Usage

      Flop.validate_and_run(Contact, params, for: Contact, backend: Kith.FlopConfig)
  """

  use Flop, repo: Kith.Repo, default_limit: 25
end
