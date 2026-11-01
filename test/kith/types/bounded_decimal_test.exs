defmodule Kith.Types.BoundedDecimalTest do
  use ExUnit.Case, async: true
  alias Kith.Types.BoundedDecimal

  test "bounds exponent and input before parsing while preserving ordinary money" do
    for value <- [
          "1e1000000000",
          "1e-1000000000",
          "1e101",
          "1e-101",
          String.duplicate("1", 129),
          "NaN",
          "Infinity"
        ] do
      assert :error = BoundedDecimal.cast(value)
    end

    assert {:ok, value} = BoundedDecimal.cast("123.45")
    assert Decimal.to_string(value, :normal) == "123.45"
    assert {:ok, value} = BoundedDecimal.cast("1.25e2")
    assert Decimal.to_string(value, :normal) == "125"
  end

  test "every user-editable money schema rejects exponent payloads" do
    for schema <- [Kith.Contacts.Debt, Kith.Contacts.Gift, Kith.Contacts.DebtPayment] do
      changeset = schema.changeset(struct(schema), %{"amount" => "1e999999999"})
      assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :amount)
    end
  end

  test "preconstructed decimals cannot bypass the exponent boundary" do
    assert :error = BoundedDecimal.cast(%Decimal{sign: 1, coef: 1, exp: 1_000_000})
    assert :error = BoundedDecimal.cast(%Decimal{sign: 1, coef: :NaN, exp: 0})
  end
end
