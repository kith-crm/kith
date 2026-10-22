defmodule Kith.Imports.Sources.VCard do
  @behaviour Kith.Imports.Source

  alias Kith.Contacts
  alias Kith.Imports
  alias Kith.VCard.Parser

  require Logger

  @impl true
  def name, do: "vCard"

  @impl true
  def file_types, do: [".vcf"]

  @impl true
  def supports_api?, do: false

  @impl true
  def validate_file(data) do
    if String.contains?(data, "BEGIN:VCARD") do
      {:ok, %{}}
    else
      {:error, "File does not appear to be a valid vCard file"}
    end
  end

  @impl true
  def parse_summary(data) do
    case Parser.parse(data, per_card: true) do
      {:ok, contacts} -> {:ok, %{contacts: length(contacts)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def import(account_id, _user_id, data, opts) do
    import_record = opts[:import]

    case Parser.parse(data, per_card: true) do
      {:ok, parsed_contacts} ->
        total = length(parsed_contacts)
        topic = "import:#{account_id}"
        broadcast_interval = max(1, div(total, 50))

        ctx = %{
          account_id: account_id,
          import_record: import_record,
          topic: topic,
          total: total,
          broadcast_interval: broadcast_interval
        }

        result =
          parsed_contacts
          |> Enum.with_index(1)
          |> Enum.reduce(
            %{contacts: 0, notes: 0, skipped: 0, error_count: 0, errors: []},
            fn {parsed, idx}, acc ->
              maybe_check_cancelled(import_record, idx)
              result = import_single_vcard(ctx, parsed, idx, acc)
              maybe_broadcast_progress(ctx, idx)
              result
            end
          )

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :cancelled ->
      {:ok, %{contacts: 0, notes: 0, skipped: 0, error_count: 0, errors: ["Import cancelled"]}}
  end

  defp maybe_check_cancelled(import_record, idx) do
    if import_record && rem(idx, 10) == 0 do
      refreshed = Imports.get_import!(import_record.id)
      if refreshed.status == "cancelled", do: throw(:cancelled)
    end
  end

  defp import_single_vcard(ctx, parsed, idx, acc) do
    case Contacts.import_contact(ctx.account_id, parsed) do
      {:ok, contact} ->
        maybe_record_vcard_entity(ctx.import_record, idx, contact.id)
        %{acc | contacts: acc.contacts + 1}

      {:error, reason} ->
        add_error(acc, "Contact #{idx}: #{inspect(reason)}")
    end
  rescue
    e ->
      add_error(acc, "Contact #{idx}: #{Exception.message(e)}")
  end

  defp maybe_record_vcard_entity(nil, _idx, _contact_id), do: :ok

  defp maybe_record_vcard_entity(import_record, idx, contact_id) do
    Imports.record_imported_entity(
      import_record,
      "contact",
      "vcard-#{idx}",
      "contact",
      contact_id
    )
  end

  defp maybe_broadcast_progress(ctx, idx) do
    if rem(idx, ctx.broadcast_interval) == 0 || idx == ctx.total do
      Phoenix.PubSub.broadcast(
        Kith.PubSub,
        ctx.topic,
        {:import_progress, %{current: idx, total: ctx.total}}
      )
    end
  end

  defp add_error(acc, msg) do
    errors = if length(acc.errors) < 50, do: acc.errors ++ [msg], else: acc.errors
    %{acc | skipped: acc.skipped + 1, error_count: acc.error_count + 1, errors: errors}
  end
end
