defmodule Kith.Imports.Monica.NoteTimestamps do
  @moduledoc """
  Extracts original note timestamps from a Monica note payload for use as
  `Kith.Contacts.create_note/4` options.
  """

  @spec from_note(map()) :: [inserted_at: DateTime.t() | nil, updated_at: DateTime.t() | nil]
  def from_note(note) when is_map(note) do
    updated_at = parse(note["updated_at"])
    inserted_at = parse(note["created_at"]) || updated_at
    [inserted_at: inserted_at, updated_at: updated_at || inserted_at]
  end

  defp parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        DateTime.truncate(dt, :second)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} ->
            naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

          _ ->
            nil
        end
    end
  end

  defp parse(_), do: nil
end
