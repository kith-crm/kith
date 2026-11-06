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
    * `coupled_fields` — a date and its year-unknown flag, resolved together.

  `display_name` is deliberately absent: it is computed by
  `Contact.compute_display_name/1` and recomputed asynchronously by
  `Kith.Workers.DisplayNameRecomputeWorker`.
  """

  alias Kith.Contacts.Contact

  @choice_fields ~w(
    first_name middle_name last_name nickname
    birthdate
    description avatar occupation company
    gender_id currency_id
    first_met_at first_met_where
    first_met_through_id first_met_additional_info
  )a

  @policy_fields ~w(favorite is_archived deceased deceased_at)a
  @array_fields ~w(aliases)a
  @immich_fields ~w(immich_person_id immich_person_url immich_status immich_last_synced_at)a

  # A date and the flag saying whether its year is real. Resolved as one unit:
  # taking the date from one member and the flag from another produces a
  # contact that claims a placeholder year (1900) is a known birth year. Both
  # flags are `null: false` with `default: false`, so they must never resolve
  # to `:clear`.
  @coupled_fields [
    {:birthdate, :birthdate_year_unknown},
    {:first_met_at, :first_met_year_unknown}
  ]

  @doc "Scalars the user picks between."
  def choice_fields, do: @choice_fields

  @doc "Fields resolved by policy rather than by user choice."
  def policy_fields, do: @policy_fields

  @doc "Array columns resolved as a deduplicated union."
  def array_fields, do: @array_fields

  @doc "Immich integration state, moved as a single unit."
  def immich_fields, do: @immich_fields

  @doc "Date columns paired with the flag describing their year."
  def coupled_fields, do: @coupled_fields

  @doc "The flag half of every coupled pair."
  def coupled_flags, do: Enum.map(@coupled_fields, &elem(&1, 1))

  @doc "Every mergeable field."
  def all do
    @choice_fields ++ @policy_fields ++ @array_fields ++ @immich_fields ++ coupled_flags()
  end

  @doc "Whether `field` is a field the merge engine knows how to resolve."
  def known?(field), do: field in all()

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
  `validate_required/2` names, so the column check is the only thing standing
  between them and a crash on the cluster merge screen.

  Read from `information_schema` rather than restated here so a column added
  with `null: false` later is covered on its own.
  """
  def non_clearable do
    cached(:non_clearable, fn ->
      changeset_required =
        %Contact{}
        |> Contact.update_changeset(%{})
        |> Map.fetch!(:required)

      Enum.uniq(changeset_required ++ not_null_fields())
    end)
  end

  @doc """
  Mergeable fields backed by a `NOT NULL` column on `contacts`.
  """
  def not_null_fields do
    cached(:not_null_fields, &query_not_null_fields/0)
  end

  # Both halves of `non_clearable/0` are cached, not just the query: the
  # changeset half builds a `%Contact{}` and runs `update_changeset/2` over it,
  # and `non_clearable?/1` is called once per choice field per render — 17
  # changesets a render — and again for every field inside the merge
  # transaction.
  #
  # `:persistent_term` because both answers are properties of the deployed
  # schema and the compiled changeset, so they cannot change while the node is
  # running. A migration that relaxes a nullability constraint is picked up on
  # the next restart, which is when the migration's own deploy happens anyway;
  # there is no purge path because nothing would call it.
  defp cached(name, fun) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        value = fun.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  # Compared as strings and filtered against the registry, so no atom is
  # created from a database identifier.
  #
  # Scoped to `current_schema()`: `information_schema.columns` spans every
  # schema in the database, so without it any other `contacts` table — a
  # leftover, a second tenant schema — contributes its `NOT NULL` columns to
  # the union, and a column nullable here but `NOT NULL` there would be
  # reported non-clearable and hide the "Leave empty" button.
  defp query_not_null_fields do
    %{rows: rows} =
      Kith.Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_name = 'contacts'
        AND table_schema = current_schema()
        AND is_nullable = 'NO'
      """)

    names = rows |> List.flatten() |> MapSet.new()

    Enum.filter(all(), &MapSet.member?(names, Atom.to_string(&1)))
  end

  @doc "Whether `field` may be cleared."
  def non_clearable?(field), do: field in non_clearable()
end
