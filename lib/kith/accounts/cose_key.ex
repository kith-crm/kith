defmodule Kith.Accounts.CoseKey do
  @moduledoc """
  Decodes server-stored public COSE keys, without admitting arbitrary ETF terms.

  The size bound precedes decoding. Compressed ETF is deliberately unsupported:
  bounding its encoded bytes would not bound the allocation during decompression.
  """

  @max_bytes 8192
  @rsa_algorithms [-65_535, -259, -258, -257, -39, -38, -37]

  @spec decode(term()) :: {:ok, map()} | {:error, :invalid_key}
  def decode(<<131, tag, _::binary>> = binary)
      when tag != 80 and byte_size(binary) <= @max_bytes do
    {key, used} = :erlang.binary_to_term(binary, [:safe, :used])

    if used == byte_size(binary) and valid?(key),
      do: {:ok, key},
      else: {:error, :invalid_key}
  rescue
    ArgumentError -> {:error, :invalid_key}
  end

  def decode(_), do: {:error, :invalid_key}

  defp valid?(key) when is_map(key) and map_size(key) <= 8 do
    Enum.all?(key, fn {k, v} -> is_integer(k) and (is_integer(v) or is_binary(v)) end) and
      valid_public_key?(key)
  end

  defp valid?(_), do: false

  defp valid_public_key?(%{1 => 2, 3 => alg, -1 => curve, -2 => x, -3 => y}) do
    size = %{1 => 32, 2 => 48, 3 => 66, 8 => 32}[curve]
    expected_alg = %{1 => -7, 2 => -35, 3 => -36, 8 => -47}[curve]
    size != nil and alg == expected_alg and sized_binary?(x, size) and sized_binary?(y, size)
  end

  defp valid_public_key?(%{1 => 3, 3 => alg, -1 => n, -2 => e})
       when alg in @rsa_algorithms and is_binary(n) and is_binary(e) do
    byte_size(n) in 256..1024 and byte_size(e) in 1..8 and
      :binary.decode_unsigned(n) > 0 and :binary.decode_unsigned(e) >= 3
  end

  defp valid_public_key?(%{1 => 1, 3 => -8, -1 => curve, -2 => x}) when curve in [6, 7] do
    sized_binary?(x, if(curve == 6, do: 32, else: 57))
  end

  defp valid_public_key?(_), do: false

  defp sized_binary?(value, size), do: is_binary(value) and byte_size(value) == size
end
