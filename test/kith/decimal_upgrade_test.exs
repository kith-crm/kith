defmodule Kith.DecimalUpgradeTest do
  use Kith.DataCase, async: true

  import Kith.Factory

  alias Kith.Contacts.{Debt, DebtPayment, Gift}
  alias Kith.{Debts, Gifts}
  alias Kith.Types.BoundedDecimal

  test "numeric(12,2) maximum persists through all money schemas" do
    {account, user} = setup_account()
    contact = insert(:contact, account: account)
    maximum = "9999999999.99"

    assert {:ok, debt} =
             Debts.create_debt(account.id, user.id, %{
               "contact_id" => contact.id,
               "title" => "Maximum debt",
               "direction" => "owed_to_me",
               "amount" => maximum
             })

    assert {:ok, gift} =
             Gifts.create_gift(account.id, user.id, %{
               "contact_id" => contact.id,
               "name" => "Maximum gift",
               "direction" => "given",
               "amount" => maximum
             })

    assert {:ok, payment} =
             Debts.add_payment(debt, %{"amount" => maximum, "paid_at" => "2026-11-01"})

    for row <- [debt, gift, payment] do
      assert Decimal.equal?(Repo.reload!(row).amount, Decimal.new(maximum))
    end

    assert Debts.get_debt!(account.id, debt.id).status == "settled"
    assert Decimal.equal?(Debts.outstanding_balance(debt), Decimal.new(0))
  end

  test "mixed fractional payments preserve cents and settle exactly" do
    {account, user} = setup_account()
    contact = insert(:contact, account: account)

    debt =
      insert(:debt,
        account: account,
        contact: contact,
        creator: user,
        amount: Decimal.new("0.30")
      )

    assert {:ok, _} = Debts.add_payment(debt, %{"amount" => "0.10", "paid_at" => "2026-11-01"})
    assert Decimal.equal?(Debts.outstanding_balance(debt), Decimal.new("0.20"))
    assert Debts.get_debt!(account.id, debt.id).status == "active"
    assert {:ok, _} = Debts.add_payment(debt, %{"amount" => "2e-1", "paid_at" => "2026-11-01"})
    assert Decimal.equal?(Debts.outstanding_balance(debt), Decimal.new("0.00"))
    assert Debts.get_debt!(account.id, debt.id).status == "settled"
  end

  test "fixed-scale rounding agrees with PostgreSQL storage for positive and negative gifts" do
    {account, user} = setup_account()
    contact = insert(:contact, account: account)

    for {input, expected} <- [{"1.235", "1.24"}, {"-1.235", "-1.24"}, {"0", "0.00"}] do
      assert {:ok, gift} =
               Gifts.create_gift(account.id, user.id, %{
                 "contact_id" => contact.id,
                 "name" => "Rounding",
                 "direction" => "received",
                 "amount" => input
               })

      assert Decimal.equal?(Repo.reload!(gift).amount, Decimal.new(expected))
      assert Decimal.equal?(Decimal.round(Decimal.new(input), 2), Decimal.new(expected))
    end
  end

  test "finite input limits remain enforced with Decimal 3 parsing defaults" do
    for input <- [
          "1e101",
          "1e-101",
          "1e1000000000",
          String.duplicate("9", 129),
          "NaN",
          "Infinity"
        ] do
      assert :error = BoundedDecimal.cast(input)

      for schema <- [Debt, DebtPayment, Gift] do
        changeset = schema.changeset(struct(schema), %{"amount" => input})
        assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :amount)
      end
    end

    for schema <- [Debt, DebtPayment], input <- ["0", "-0.01"] do
      changeset = schema.changeset(struct(schema), %{"amount" => input})
      assert {"must be greater than %{number}", _} = Keyword.fetch!(changeset.errors, :amount)
    end
  end
end
