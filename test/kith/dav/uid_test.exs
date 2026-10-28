defmodule Kith.DAV.UIDTest do
  use ExUnit.Case, async: true
  alias Kith.DAV.UID

  test "normalizes bare and URN UUIDs without accepting unrelated text" do
    uuid = "123e4567-e89b-12d3-a456-426614174000"

    for value <- [
          uuid,
          String.upcase(uuid),
          "urn:uuid:" <> uuid,
          "URN:UUID:" <> String.upcase(uuid)
        ] do
      assert UID.normalize(value) == {:ok, uuid}
      assert UID.urn(value) == "urn:uuid:" <> uuid
    end

    for value <- [
          nil,
          "",
          "x",
          "https://example.com/person",
          "urn:uuid:urn:uuid:" <> uuid,
          String.replace(uuid, "-", ""),
          uuid <> "\n",
          " " <> uuid
        ] do
      assert UID.normalize(value) == {:error, :invalid_uid}
      assert UID.urn(value) == nil
    end
  end
end
