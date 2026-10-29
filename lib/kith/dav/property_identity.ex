defmodule Kith.DAV.PropertyIdentity do
  @moduledoc "Shared CLIENTPIDMAP source tables and PID interpretation for document and native matching."

  alias Kith.DAV.UID
  alias Kith.VCard.Document.{Parameter, Property}

  @doc "Builds a normalized source table, rejecting conflicting uses of one source index."
  def sources(properties) do
    Enum.reduce_while(properties, {:ok, %{}}, &add_source/2)
  end

  defp add_source(property, {:ok, sources}) do
    if property_name(property) == "CLIENTPIDMAP" do
      put_source(property_value(property), sources)
    else
      {:cont, {:ok, sources}}
    end
  end

  defp put_source(value, sources) do
    case String.split(value, ";", parts: 2) do
      [index, uri] when index != "" and uri != "" ->
        uri = source(uri)

        if Map.has_key?(sources, index) and sources[index] != uri,
          do: {:halt, {:error, :ambiguous_property_identity}},
          else: {:cont, {:ok, Map.put(sources, index, uri)}}

      _ ->
        {:cont, {:ok, sources}}
    end
  end

  @doc "Extracts source-qualified identities; unknown sources and malformed PIDs do not match."
  def pids(nil, _sources), do: MapSet.new()

  def pids(property, sources) do
    property_params(property)
    |> Enum.filter(&(parameter_name(&1) == "PID"))
    |> Enum.flat_map(&parameter_values/1)
    |> Enum.flat_map(&pid_identity(&1, sources))
    |> MapSet.new()
  end

  defp pid_identity(value, sources) do
    case String.split(value, ".") do
      [local] -> [{:local, local}]
      [local, index] -> if uri = sources[index], do: [{uri, local}], else: []
      _ -> []
    end
  end

  defp property_name(%Property{normalized_name: name}), do: name
  defp property_name(property), do: property["normalized_name"]
  defp property_value(%Property{value: value}), do: value
  defp property_value(property), do: property["value"]
  defp property_params(%Property{parameters: parameters}), do: parameters
  defp property_params(property), do: property["parameters"] || []
  defp parameter_name(%Parameter{normalized_name: name}), do: name
  defp parameter_name(parameter), do: parameter["normalized_name"]
  defp parameter_values(%Parameter{values: values}), do: values
  defp parameter_values(parameter), do: parameter["values"]

  def source(value) when is_binary(value) do
    case UID.normalize(value) do
      {:ok, uuid} ->
        UID.urn(uuid)

      _ ->
        normalized = normalize_uri(value)

        case UID.normalize(normalized) do
          {:ok, uuid} -> UID.urn(uuid)
          _ -> normalized
        end
    end
  end

  defp normalize_uri(value) do
    case URI.new(normalize_percent_encoding(value)) do
      {:ok, %URI{scheme: scheme} = uri} when is_binary(scheme) ->
        %{uri | scheme: String.downcase(scheme), host: lowercase(uri.host)}
        |> URI.to_string()

      _ ->
        value
    end
  end

  defp lowercase(nil), do: nil
  defp lowercase(value), do: String.downcase(value)

  # Decode only unreserved ASCII; reserved delimiters retain their semantics.
  # Do not case-fold paths, queries, fragments, URN namespaces or opaque parts.
  defp normalize_percent_encoding(value) do
    Regex.replace(~r/%([0-9a-fA-F]{2})/, value, fn _raw, hex ->
      byte = String.to_integer(hex, 16)
      if unreserved?(byte), do: <<byte>>, else: "%" <> String.upcase(hex)
    end)
  end

  defp unreserved?(byte),
    do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in ~c"-._~"
end
