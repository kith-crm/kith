defmodule Kith.VCard.Document do
  @moduledoc """
  An ordered, source-version vCard document without contact-field mappings.

  This layer retains property groups, repetitions, raw values and ordered raw
  parameters. It deliberately does not interpret native contact values, validate
  property cardinalities beyond VERSION, or convert between vCard versions.
  `serialize/1` normalizes line endings and folding, but otherwise preserves
  content-line syntax. Internal bindings must be added separately by trusted DAV
  code; wire properties do not carry native row identity here.
  """

  alias Kith.VCard.Parser

  defmodule Parameter do
    @moduledoc "An ordered parameter occurrence, with raw syntax and decoded values."
    @enforce_keys [:name, :normalized_name, :raw, :values]
    defstruct [:name, :normalized_name, :raw, :values]

    @type t :: %__MODULE__{
            name: String.t(),
            normalized_name: String.t(),
            raw: String.t(),
            values: [String.t()]
          }
  end

  defmodule Property do
    @moduledoc "One content-line occurrence; value remains escaped source syntax."
    @enforce_keys [:name, :normalized_name, :parameters, :value]
    defstruct [:group, :name, :normalized_name, :parameters, :value]

    @type t :: %__MODULE__{
            group: String.t() | nil,
            name: String.t(),
            normalized_name: String.t(),
            parameters: [Parameter.t()],
            value: String.t()
          }
  end

  @enforce_keys [:source_version, :properties]
  defstruct [:source_version, :properties]

  @type t :: %__MODULE__{source_version: :v30 | :v40, properties: [Property.t()]}

  @doc "Decodes exactly one vCard 3.0 or 4.0 document, without dropping unknown lines."
  def parse(data) when is_binary(data) do
    with {:ok, lines} <- content_lines(data),
         {:ok, interior} <- envelope(lines),
         {:ok, version} <- version(interior),
         {:ok, properties} <- parse_properties(interior, version) do
      {:ok, %__MODULE__{source_version: version, properties: properties}}
    end
  end

  @doc "Serializes the same source version, with CRLF and UTF-8-safe 75-octet folding."
  def serialize(%__MODULE__{properties: properties} = document) do
    validate_source_version!(document)

    ["BEGIN:VCARD" | Enum.map(properties, &property_line/1)]
    |> Kernel.++(["END:VCARD"])
    |> Enum.map_join("\r\n", &fold/1)
    |> Kernel.<>("\r\n")
  end

  defp validate_source_version!(%__MODULE__{source_version: version, properties: properties}) do
    versions = Enum.filter(properties, &(&1.normalized_name == "VERSION"))

    unless valid_version_property?(versions, properties, version),
      do: raise(ArgumentError, "document VERSION must match its source_version")
  end

  defp valid_version_property?(
         [%Property{name: name, group: nil, parameters: [], value: value} = property],
         properties,
         version
       ) do
    String.upcase(name) == "VERSION" and
      valid_version_position?(version, value, property, properties)
  end

  defp valid_version_property?(_, _, _), do: false
  defp valid_version_position?(:v30, "3.0", _property, _properties), do: true
  defp valid_version_position?(:v40, "4.0", property, [property | _]), do: true
  defp valid_version_position?(_, _, _, _), do: false

  @doc "Returns all occurrences of a property, retaining source order and groups."
  def properties(%__MODULE__{properties: properties}, name) when is_binary(name) do
    name = String.upcase(name)
    Enum.filter(properties, &(&1.normalized_name == name))
  end

  defp content_lines(data) do
    # Unfold bytes before UTF-8 validation: a client fold may bisect a code point.
    data =
      data
      |> String.replace_prefix("\uFEFF", "")
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.replace("\n ", "")
      |> String.replace("\n\t", "")

    cond do
      not String.valid?(data) ->
        {:error, :invalid_utf8}

      Regex.match?(~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/, data) ->
        {:error, :invalid_control_character}

      true ->
        lines = data |> String.trim_trailing("\n") |> String.split("\n")
        {:ok, lines}
    end
  end

  defp envelope([first | rest]) when rest != [] do
    {interior, [last]} = Enum.split(rest, -1)

    first = Regex.replace(~r/[ \t]+$/, first, "")
    last = Regex.replace(~r/[ \t]+$/, last, "")

    if String.upcase(first) == "BEGIN:VCARD" and String.upcase(last) == "END:VCARD" do
      {:ok, interior}
    else
      {:error, :invalid_envelope}
    end
  end

  defp envelope(_), do: {:error, :invalid_envelope}

  defp version(lines) do
    versions =
      Enum.with_index(lines)
      |> Enum.flat_map(&version_line/1)

    case versions do
      [{"3.0", _index}] -> {:ok, :v30}
      [{"4.0", 0}] -> {:ok, :v40}
      _ -> invalid_version()
    end
  end

  defp version_line({line, index}) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        if String.upcase(name) == "VERSION", do: [{value, index}], else: []

      _ ->
        []
    end
  end

  defp invalid_version, do: {:error, :invalid_version}

  defp parse_properties(lines, version) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case parse_property(line, version) do
        {:ok, property} -> {:cont, {:ok, [property | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} ->
        properties = Enum.reverse(reversed)

        if Enum.count(properties, &(&1.normalized_name == "VERSION")) == 1 do
          {:ok, properties}
        else
          invalid_version()
        end

      error ->
        error
    end
  end

  defp parse_property(line, version) do
    with {head, value} when is_binary(value) <- Parser.split_line(line),
         true <- balanced_quotes?(head),
         [qualified_name | raw_parameters] <- Parser.split_params(head),
         {:ok, group, name} <- property_name(qualified_name),
         false <- String.upcase(name) in ["BEGIN", "END"],
         {:ok, parameters} <- parse_parameters(raw_parameters, version),
         true <- String.upcase(name) != "VERSION" or (group == nil and parameters == []) do
      {:ok,
       %Property{
         group: group,
         name: name,
         normalized_name: String.upcase(name),
         parameters: parameters,
         value: value
       }}
    else
      _ -> {:error, :invalid_content_line}
    end
  end

  defp property_name(qualified_name) do
    case String.split(qualified_name, ".") do
      [name] ->
        if token?(name), do: {:ok, nil, name}, else: {:error, :invalid_property_name}

      [group, name] ->
        if token?(group) and token?(name),
          do: {:ok, group, name},
          else: {:error, :invalid_property_name}

      _ ->
        {:error, :invalid_property_name}
    end
  end

  defp token?(name), do: Regex.match?(~r/\A[A-Za-z0-9-]+\z/, name)

  defp parse_parameters(raw_parameters, version) do
    Enum.reduce_while(raw_parameters, {:ok, []}, fn raw, {:ok, acc} ->
      case parse_parameter(raw, version) do
        {:ok, parameter} -> {:cont, {:ok, [parameter | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parameters} -> {:ok, Enum.reverse(parameters)}
      error -> error
    end
  end

  defp parse_parameter(raw, version) do
    with [name, raw_values] <- String.split(raw, "=", parts: 2),
         true <- token?(name),
         {:ok, values} <- parameter_values(raw_values, version) do
      {:ok,
       %Parameter{
         name: name,
         normalized_name: String.upcase(name),
         raw: raw,
         values: values
       }}
    else
      _ -> {:error, :invalid_parameter}
    end
  end

  # Reuse the existing quote-aware scanner with comma translated only outside
  # quotes. Unlike Parser.params/1, a quoted comma is kept in its single value.
  defp parameter_values(raw, version) do
    values = split_parameter_values(raw)

    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case parameter_value(value) do
        {:ok, decoded} -> {:cont, {:ok, [decode_parameter(decoded, version) | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp split_parameter_values(raw) do
    {translated, _quoted} =
      for <<byte <- raw>>, reduce: {[], false} do
        {acc, quoted} ->
          case byte do
            ?" -> {[byte | acc], not quoted}
            ?, when not quoted -> {[?; | acc], quoted}
            _ -> {[byte | acc], quoted}
          end
      end

    translated |> Enum.reverse() |> IO.iodata_to_binary() |> Parser.split_params()
  end

  defp parameter_value(<<?", rest::binary>>) do
    if String.ends_with?(rest, "\"") do
      value = binary_part(rest, 0, byte_size(rest) - 1)
      if String.contains?(value, "\""), do: {:error, :invalid_parameter}, else: {:ok, value}
    else
      {:error, :invalid_parameter}
    end
  end

  defp parameter_value(value) do
    if String.contains?(value, ["\"", ":", ";"]),
      do: {:error, :invalid_parameter},
      else: {:ok, value}
  end

  defp decode_parameter(value, :v30), do: value

  defp decode_parameter(value, :v40) do
    Regex.replace(~r/\^(\^|n|N|')/, value, fn
      _, "^" -> "^"
      _, "'" -> "\""
      _, _ -> "\n"
    end)
  end

  defp balanced_quotes?(line), do: rem(length(:binary.matches(line, "\"")), 2) == 0

  defp property_line(%Property{} = property) do
    name = if property.group, do: property.group <> "." <> property.name, else: property.name
    parameters = Enum.map_join(property.parameters, "", &(";" <> &1.raw))
    name <> parameters <> ":" <> property.value
  end

  defp fold(line), do: fold(line, 75, [])
  defp fold("", _limit, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp fold(line, limit, acc) when byte_size(line) <= limit,
    do: [line | acc] |> Enum.reverse() |> IO.iodata_to_binary()

  defp fold(line, limit, acc) do
    size = utf8_boundary(line, limit)
    <<chunk::binary-size(size), rest::binary>> = line
    fold(rest, 74, ["\r\n ", chunk | acc])
  end

  defp utf8_boundary(line, size) do
    if :binary.at(line, size) in 0x80..0xBF,
      do: utf8_boundary(line, size - 1),
      else: size
  end
end
