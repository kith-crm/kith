ExUnit.start()

defmodule CalendarCompatibility.Test do
  use ExUnit.Case
  alias CalendarCompatibility.Cldr, as: Backend

  test "token registry lookup, symbol and number formatting" do
    for name <- ["BTC", "ETH", "BCH", "EOS"] do
      assert {:ok, id} = DigitalToken.validate_token(name)
      assert is_binary(id) and byte_size(id) == 9
      assert {:ok, token} = DigitalToken.get_token(id)
      assert is_struct(token, DigitalToken)
      assert {:ok, short} = DigitalToken.short_name(id)
      assert is_binary(short)
      assert {:ok, long} = DigitalToken.long_name(id)
      assert is_binary(long)

      for style <- 1..4 do
        assert {:ok, symbol} = DigitalToken.symbol(id, style)
        assert is_binary(symbol)
      end

      for locale <- ["en", "fr", "ar"] do
        assert {:ok, formatted} =
                 Backend.Number.to_string(Decimal.new("12.50"), currency: id, locale: locale)

        assert is_binary(formatted) and byte_size(formatted) > 0
      end
    end

    assert {:ok, "4H95J0R2X"} = DigitalToken.validate_token("BTC")
    assert {:ok, "₿"} = DigitalToken.symbol("BTC", 1)
    assert {:error, _} = DigitalToken.validate_token("not-a-token")
  end

  test "calendar localization, leap dates, and localized date formatting" do
    assert {:ok, date} = Date.convert(~D[2024-02-29], Cldr.Calendar.Gregorian)
    assert Date.convert!(date, Calendar.ISO) == ~D[2024-02-29]

    assert Cldr.Calendar.localize(~D[2024-02-29], :month,
             format: :wide,
             backend: Backend,
             locale: "en"
           ) == "February"

    assert Cldr.Calendar.localize(~D[2024-02-29], :month,
             format: :wide,
             backend: Backend,
             locale: "fr"
           ) == "février"

    for locale <- ["en", "fr", "ar"] do
      assert is_binary(
               Cldr.Calendar.localize(date, :month,
                 format: :wide,
                 backend: Backend,
                 locale: locale
               )
             )
    end

    assert {:error, :invalid_date} = Date.new(2023, 2, 29, Cldr.Calendar.Gregorian)
  end

  test "fiat currency and fixed-scale localized number formatting" do
    assert {:ok, "$1,234.50"} =
             Backend.Number.to_string(Decimal.new("1234.50"), currency: :USD, locale: "en")

    assert {:ok, "1,234.5"} = Backend.Number.to_string(Decimal.new("1234.50"), locale: "en")
    assert {:ok, "1 234,5"} = Backend.Number.to_string(Decimal.new("1234.50"), locale: "fr")
  end
end
