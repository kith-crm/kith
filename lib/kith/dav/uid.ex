defmodule Kith.DAV.UID do
  @moduledoc "Canonical UUID identities at the CardDAV boundary."

  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  def normalize(value) when is_binary(value) do
    value = Regex.replace(~r/\Aurn:uuid:/i, value, "")
    if Regex.match?(@uuid, value), do: Ecto.UUID.cast(value), else: {:error, :invalid_uid}
  end

  def normalize(_), do: {:error, :invalid_uid}

  def urn(value) do
    case normalize(value) do
      {:ok, uuid} -> "urn:uuid:" <> uuid
      _ -> nil
    end
  end
end
