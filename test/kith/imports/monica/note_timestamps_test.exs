defmodule Kith.Imports.Monica.NoteTimestampsTest do
  use ExUnit.Case, async: true

  alias Kith.Imports.Monica.NoteTimestamps

  test "parses created_at and updated_at" do
    note = %{"created_at" => "2024-02-20T12:00:00Z", "updated_at" => "2024-02-21T09:30:00Z"}

    assert NoteTimestamps.from_note(note) ==
             [inserted_at: ~U[2024-02-20 12:00:00Z], updated_at: ~U[2024-02-21 09:30:00Z]]
  end

  test "updated_at falls back to inserted_at" do
    assert NoteTimestamps.from_note(%{"created_at" => "2024-02-20T12:00:00Z"}) ==
             [inserted_at: ~U[2024-02-20 12:00:00Z], updated_at: ~U[2024-02-20 12:00:00Z]]
  end

  test "garbage or missing gives nils" do
    assert NoteTimestamps.from_note(%{"created_at" => "garbage"}) ==
             [inserted_at: nil, updated_at: nil]

    assert NoteTimestamps.from_note(%{}) == [inserted_at: nil, updated_at: nil]
  end

  test "offset strings are converted to UTC" do
    assert NoteTimestamps.from_note(%{"created_at" => "2024-02-20T14:00:00+02:00"})[:inserted_at] ==
             ~U[2024-02-20 12:00:00Z]
  end

  test "Monica space format is treated as UTC" do
    assert NoteTimestamps.from_note(%{"created_at" => "2024-02-20 12:00:00"})[:inserted_at] ==
             ~U[2024-02-20 12:00:00Z]
  end

  test "updated_at alone is used for both timestamps" do
    assert NoteTimestamps.from_note(%{"updated_at" => "2024-02-21T09:30:00Z"}) ==
             [inserted_at: ~U[2024-02-21 09:30:00Z], updated_at: ~U[2024-02-21 09:30:00Z]]
  end
end
