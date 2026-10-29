defmodule Kith.Types.BoundedDecimal do
  @moduledoc """
  Money input boundary for Decimal 2.x. Bounds are checked before Decimal parses
  strings, so a short exponent cannot request an enormous integer expansion.
  The database still stores the ordinary PostgreSQL decimal type.
  """
  use Ecto.Type

  @max_length 128
  @max_exponent 100
  @pattern ~r/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE]([+-]?\d{1,3}))?\z/

  def type, do: :decimal

  def cast(value) when is_binary(value) and byte_size(value) <= @max_length do
    case Regex.run(@pattern, value) do
      [_] ->
        Ecto.Type.cast(:decimal, value)

      [_, exponent] ->
        if abs(String.to_integer(exponent)) <= @max_exponent,
          do: Ecto.Type.cast(:decimal, value),
          else: :error

      _ ->
        :error
    end
  end

  def cast(%Decimal{coef: coefficient, exp: exponent} = value)
      when is_integer(coefficient) and is_integer(exponent) and
             exponent >= -@max_exponent and exponent <= @max_exponent do
    if byte_size(Integer.to_string(coefficient)) <= @max_length,
      do: {:ok, value},
      else: :error
  end

  def cast(value) when is_integer(value) or is_float(value) do
    with {:ok, decimal} <- Ecto.Type.cast(:decimal, value), do: cast(decimal)
  end

  def cast(_), do: :error
  # Existing database values are trusted persisted data. Input/dump boundaries
  # reject new extreme values without breaking reads of legacy rows.
  def load(value), do: Ecto.Type.load(:decimal, value)
  def dump(value), do: cast(value)
end
