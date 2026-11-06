defmodule Kith.Workers.DisplayNameRecomputeWorker do
  @moduledoc """
  Oban worker that recomputes `display_name` on all contacts in an account
  after a user changes their `display_name_format` preference.

  Jobs identify the requesting user and read their current preference under the
  account write lock. Pending jobs replace their args; an executing job does not
  prevent a newer job from being queued. Legacy jobs without a user ID retain
  their explicit format argument rather than guessing which account user owns it.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:worker, :args],
      keys: [:account_id],
      states: [:available, :scheduled, :retryable]
    ],
    replace: [available: [:args], scheduled: [:args], retryable: [:args]]

  import Ecto.Query
  alias Kith.Accounts.User
  alias Kith.Contacts.Contact
  alias Kith.Contacts.Write
  alias Kith.Repo

  @batch_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id} = args}) do
    recompute_batch(account_id, args, 0)
  end

  defp recompute_batch(account_id, args, offset) do
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
      ids = Enum.map(contacts, & &1.id)

      Write.run(account_id, ids, fn ->
        recompute_current_preference(account_id, contacts, args)
      end)

      recompute_batch(account_id, args, offset + @batch_size)
    end
  end

  defp recompute_current_preference(account_id, contacts, args) do
    case current_format(account_id, args) do
      {:ok, format} -> recompute_contacts(account_id, contacts, format)
      :missing_user -> :ok
    end
  end

  defp current_format(account_id, %{"user_id" => user_id}) do
    case Repo.get_by(User, id: user_id, account_id: account_id) do
      nil -> :missing_user
      user -> {:ok, user.display_name_format}
    end
  end

  # Old queued/direct jobs have no user identity. Preserve their explicit native
  # edit intent; choosing any current account member would cross user preferences.
  defp current_format(_account_id, args),
    do: {:ok, Map.get(args, "display_name_format", "first_last")}

  defp recompute_contacts(account_id, contacts, format) do
    Enum.each(contacts, fn snapshot ->
      contact = Repo.get_by!(Contact, id: snapshot.id, account_id: account_id)
      new_display_name = compute_display_name(contact, format)

      from(c in Contact, where: c.id == ^contact.id)
      |> Repo.update_all(set: [display_name: new_display_name])
    end)
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
