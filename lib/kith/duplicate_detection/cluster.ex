defmodule Kith.DuplicateDetection.Cluster do
  @moduledoc """
  A derived group of contacts that detection believes are the same person.

  Clusters have no database row — they are computed from `duplicate_candidates`
  on every read, so they cannot drift from the pairs that justify them. `key` is
  the lowest member contact id and is used for routing.
  """

  defstruct [:key, :contacts, :pairs, :max_score, :reasons]

  @type t :: %__MODULE__{
          key: integer(),
          contacts: [Kith.Contacts.Contact.t()],
          pairs: [Kith.Contacts.DuplicateCandidate.t()],
          max_score: float(),
          reasons: [String.t()]
        }
end
