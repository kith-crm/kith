defmodule Kith.Workers.DisplayNameRecomputeWorker do
  @moduledoc """
  Oban worker that recomputes `display_name` on all contacts in an account
  after a user changes their `display_name_format` preference.

  Idempotent: if the format changes again before this job runs, the newer
  job will produce the correct final state regardless.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, fields: [:args], keys: [:account_id]]

  import Ecto.Query
  alias Kith.Contacts.Contact
  alias Kith.Repo

  @batch_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "display_name_format" => format}}) do
    recompute_batch(account_id, format, 0)
  end

  defp recompute_batch(account_id, format, offset) do
    contacts =
      from(c in Contact,
        where: c.account_id == ^account_id,
        where: is_nil(c.deleted_at),
        order_by: [asc: c.id],
        offset: ^offset,
        limit: @batch_size,
        select: [:id, :first_name, :last_name, :nickname]
      )
      |> Repo.all()

    if contacts == [] do
      :ok
    else
      Enum.each(contacts, fn contact ->
        new_display_name = compute_display_name(contact, format)

        from(c in Contact, where: c.id == ^contact.id)
        |> Repo.update_all(set: [display_name: new_display_name])
      end)

      ids = Enum.map(contacts, & &1.id)

      owners =
        Repo.all(
          from(r in Kith.Contacts.Relationship,
            where: r.related_contact_id in ^ids,
            select: r.contact_id
          )
        )

      Kith.DAV.Store.touch(account_id, ids ++ owners)
      recompute_batch(account_id, format, offset + @batch_size)
    end
  end

  defp compute_display_name(contact, format) do
    first = contact.first_name || ""
    last = contact.last_name || ""
    format_name(first, last, format)
  end

  defp format_name(first, last, "first_last"), do: String.trim("#{first} #{last}")
  defp format_name(first, last, "last_first"), do: String.trim("#{last} #{first}")
  defp format_name(first, _last, "first_only"), do: first

  defp format_name(first, last, "last_first_comma") do
    if last != "" and first != "",
      do: "#{last}, #{first}",
      else: String.trim("#{last}#{first}")
  end

  defp format_name(first, last, _), do: String.trim("#{first} #{last}")
end
