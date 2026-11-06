defmodule Kith.Contacts.FieldProtocol do
  @moduledoc "Shared normalization for contact field protocol tokens."

  def normalize(nil), do: nil

  def normalize(protocol) when is_binary(protocol) do
    protocol
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing("://")
    |> String.trim_trailing(":")
  end
end
