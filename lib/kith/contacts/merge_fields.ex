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
  Fields that cannot be set to `:clear`, derived from the contact update
  changeset's `validate_required/2` list rather than maintained by hand.
  """
  def non_clearable do
    %Contact{}
    |> Contact.update_changeset(%{})
    |> Map.fetch!(:required)
  end

  @doc "Whether `field` may be cleared."
  def non_clearable?(field), do: field in non_clearable()
end
