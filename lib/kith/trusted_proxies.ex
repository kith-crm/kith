defmodule Kith.TrustedProxies do
  @moduledoc """
  Exact ingress identities and the canonical client address shared by HTTP and sockets.

  Only one literal address supplied by an allowlisted socket peer is authoritative.
  Forwarded chains and other forwarded headers never participate in this decision.
  """

  import Bitwise, only: [band: 2, bsr: 2]

  @header "x-kith-client-ip"
  @max_config_bytes 4096
  @max_proxies 32
  @max_address_bytes 45

  @doc "Parses literal ingress addresses, permitting only explicit /32 or /128 host masks."
  def parse!(configuration) when is_binary(configuration) do
    if byte_size(configuration) > @max_config_bytes do
      invalid_configuration!()
    end

    case String.trim(configuration) do
      "" ->
        []

      configuration ->
        entries = String.split(configuration, ",")
        if length(entries) > @max_proxies, do: invalid_configuration!()
        entries |> Enum.map(&parse_entry!/1) |> Enum.uniq()
    end
  end

  def parse!(_configuration), do: invalid_configuration!()

  @doc "Resolves a socket peer and raw header tuples using the configured ingress allowlist."
  def resolve(peer, headers) do
    resolve(peer, headers, Application.get_env(:kith, :trusted_proxies, []))
  end

  @doc "Resolves a socket peer and raw header tuples using explicit normalized ingress addresses."
  def resolve(peer, headers, allowlist) do
    peer = normalize(peer)

    if valid_address?(peer) and peer in allowlist do
      case client_address(headers) do
        {:ok, address} -> normalize(address)
        :error -> peer
      end
    else
      peer
    end
  end

  @doc "Maps IPv4-mapped IPv6 addresses to the same identity as their IPv4 representation."
  def normalize({0, 0, 0, 0, 0, 65_535, high, low})
      when is_integer(high) and high in 0..65_535 and is_integer(low) and low in 0..65_535 do
    {bsr(high, 8), band(high, 255), bsr(low, 8), band(low, 255)}
  end

  def normalize(address), do: address

  defp parse_entry!(entry) do
    case entry |> String.trim() |> String.split("/") do
      [address] ->
        address |> parse_address!() |> normalize()

      [address, mask] ->
        parsed = parse_address!(address)
        required_mask = if tuple_size(parsed) == 4, do: "32", else: "128"
        if mask != required_mask, do: invalid_configuration!()
        normalize(parsed)

      _ ->
        invalid_configuration!()
    end
  end

  defp parse_address!(address) do
    case strict_address(address) do
      {:ok, parsed} -> parsed
      :error -> invalid_configuration!()
    end
  end

  defp client_address(headers) when is_list(headers) do
    values =
      for {name, value} <- headers,
          is_binary(name),
          String.valid?(name),
          String.downcase(name) == @header,
          do: value

    case values do
      [value] when is_binary(value) -> strict_address(value)
      _ -> :error
    end
  end

  defp client_address(_headers), do: :error

  defp strict_address(value) when byte_size(value) in 1..@max_address_bytes do
    if String.valid?(value) do
      case :inet.parse_strict_address(String.to_charlist(value)) do
        {:ok, address} -> {:ok, address}
        {:error, _reason} -> :error
      end
    else
      :error
    end
  end

  defp strict_address(_value), do: :error

  defp valid_address?({a, b, c, d}) do
    Enum.all?([a, b, c, d], &(is_integer(&1) and &1 in 0..255))
  end

  defp valid_address?(address) when is_tuple(address) and tuple_size(address) == 8 do
    address |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 in 0..65_535))
  end

  defp valid_address?(_address), do: false

  @spec invalid_configuration!() :: no_return()
  defp invalid_configuration! do
    raise ArgumentError,
          "TRUSTED_PROXIES must contain at most 32 literal IP addresses with optional /32 or /128 host masks"
  end
end
