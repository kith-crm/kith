defmodule Kith.Contacts.MergeFields do
  @moduledoc """
  Declares which `Kith.Contacts.Contact` fields participate in a merge and how
  each is treated.

  Four groups:

    * `choice_fields` — ordinary scalars the user picks between.
    * `policy_fields` — booleans and their companions, resolved by policy
      rather than by choice (see `Kith.Contacts.MergeResolution`).
    * `array_fields` — array columns resolved as a deduplicated union.
    * `immich_fields` — integration state that moves as one unit.

  `display_name` is deliberately absent: it is computed by
  `Contact.compute_display_name/1` and recomputed asynchronously by
  `Kith.Workers.DisplayNameRecomputeWorker`.
  """

  alias Kith.Contacts.Contact

  @choice_fields ~w(
    first_name middle_name last_name nickname
    birthdate birthdate_year_unknown
    description avatar occupation company
    gender_id currency_id
    first_met_at first_met_year_unknown first_met_where
    first_met_through_id first_met_additional_info
  )a

  @policy_fields ~w(favorite is_archived deceased deceased_at)a
  @array_fields ~w(aliases)a
  @immich_fields ~w(immich_person_id immich_person_url immich_status immich_last_synced_at)a

  @doc "Scalars the user picks between."
  def choice_fields, do: @choice_fields

  @doc "Fields resolved by policy rather than by user choice."
  def policy_fields, do: @policy_fields

  @doc "Array columns resolved as a deduplicated union."
  def array_fields, do: @array_fields

  @doc "Immich integration state, moved as a single unit."
  def immich_fields, do: @immich_fields

  @doc "Every mergeable field."
  def all, do: @choice_fields ++ @policy_fields ++ @array_fields ++ @immich_fields

  @doc """
  Fields that cannot be set to `:clear`.

  Two sources, neither maintained by hand:

    * the contact update changeset's `validate_required/2` list, and
    * every `contacts` column declared `NOT NULL`.

  The second half is not optional. `:clear` becomes `nil` at the database, so a
  `NOT NULL` column raises a `Postgrex.Error` (SQLSTATE 23502) outside the
  merge engine's documented `{:error, reason}` contract — and the changeset's
  required list does not cover them: `birthdate_year_unknown` and
  `first_met_year_unknown` are `null: false` booleans that no
  `validate_required/2` names, so they were offered as clearable and two clicks
  on the cluster merge screen crashed the LiveView.

  Read from `information_schema` rather than restated here so a column added
  with `null: false` later is covered on its own.
  """
  def non_clearable do
    changeset_required =
      %Contact{}
      |> Contact.update_changeset(%{})
      |> Map.fetch!(:required)

    Enum.uniq(changeset_required ++ not_null_fields())
  end

  @doc """
  Mergeable fields backed by a `NOT NULL` column on `contacts`.

  Cached in `:persistent_term` — the answer is a property of the deployed
  schema, and `non_clearable?/1` is called once per field per render and again
  for every field inside the merge transaction.
  """
  def not_null_fields do
    key = {__MODULE__, :not_null_fields}

    case :persistent_term.get(key, nil) do
      nil ->
        fields = query_not_null_fields()
        :persistent_term.put(key, fields)
        fields

      fields ->
        fields
    end
  end

  # Compared as strings and filtered against the registry, so no atom is
  # created from a database identifier.
  defp query_not_null_fields do
    %{rows: rows} =
      Kith.Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_name = 'contacts' AND is_nullable = 'NO'
      """)

    names = rows |> List.flatten() |> MapSet.new()

    Enum.filter(all(), &MapSet.member?(names, Atom.to_string(&1)))
  end

  @doc "Whether `field` may be cleared."
  def non_clearable?(field), do: field in non_clearable()
end
