defmodule Kith.Workers.PhoneRenormalizeWorker do
  @moduledoc """
  One-shot Oban worker that re-normalizes existing phone-protocol contact_fields
  to E.164 using each account's locale-derived region.

  Run once after the libphonenumber-backed `PhoneFormatter.normalize/2` lands,
  to migrate values written under the previous heuristic (e.g. "5551234567"
  stored without a country code) into canonical E.164 form so the detection
  worker can match by plain equality.

  Args:
    * `"account_id"` (optional) — scope to a single account; omit to process all.

  Idempotent: rows whose normalized form already equals the stored value are
  skipped, so re-running is safe.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Kith.Accounts.Account
  alias Kith.Contacts.{ContactField, ContactFieldType, PhoneFormatter}
  alias Kith.Repo

  require Logger

  @batch_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    renormalize_account(account_id)
    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    account_ids = Repo.all(from(a in Account, select: a.id))
    Enum.each(account_ids, &renormalize_account/1)
    :ok
  end

  defp renormalize_account(account_id) do
    region =
      Repo.one(from(a in Account, where: a.id == ^account_id, select: a.locale))
      |> PhoneFormatter.region_for_locale()

    # ContactFieldTypes can be either system-wide (`account_id IS NULL`) or
    # account-specific. Match both — the detection worker uses the same
    # protocol-only filter so this mirrors that.
    phone_cft_ids =
      from(t in ContactFieldType,
        where: is_nil(t.account_id) or t.account_id == ^account_id,
        where: fragment("? LIKE 'tel%'", t.protocol),
        select: t.id
      )
      |> Repo.all()

    if phone_cft_ids != [] do
      renormalize_batch(account_id, phone_cft_ids, region, 0, 0)
    end
  end

  defp renormalize_batch(account_id, cft_ids, region, offset, updated_count) do
    rows =
      from(cf in ContactField,
        where: cf.account_id == ^account_id,
        where: cf.contact_field_type_id in ^cft_ids,
        order_by: [asc: cf.id],
        offset: ^offset,
        limit: @batch_size,
        select: {cf.id, cf.value}
      )
      |> Repo.all()

    if rows == [] do
      Logger.info("[PhoneRenormalizeWorker] account=#{account_id} done, updated=#{updated_count}")

      :ok
    else
      batch_updated = count_updates(rows, region)

      renormalize_batch(
        account_id,
        cft_ids,
        region,
        offset + @batch_size,
        updated_count + batch_updated
      )
    end
  end

  defp count_updates(rows, region) do
    Enum.reduce(rows, 0, fn {id, value}, acc ->
      acc + update_to_int(maybe_update(id, value, region))
    end)
  end

  defp update_to_int(:updated), do: 1
  defp update_to_int(:unchanged), do: 0

  defp maybe_update(_id, nil, _region), do: :unchanged
  defp maybe_update(_id, "", _region), do: :unchanged

  defp maybe_update(id, value, region) do
    {:ok, normalized} = PhoneFormatter.normalize(value, region)

    if normalized && normalized != value do
      from(cf in ContactField, where: cf.id == ^id)
      |> Repo.update_all(set: [value: normalized])

      :updated
    else
      :unchanged
    end
  end
end
