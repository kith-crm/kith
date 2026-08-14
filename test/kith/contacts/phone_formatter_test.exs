defmodule Kith.Contacts.PhoneFormatterTest do
  use ExUnit.Case, async: true

  alias Kith.Contacts.PhoneFormatter

  describe "normalize/1 (no region — opt-in normalization)" do
    test "returns nil for nil" do
      assert {:ok, nil} = PhoneFormatter.normalize(nil)
    end

    test "returns nil for empty string" do
      assert {:ok, nil} = PhoneFormatter.normalize("")
    end

    test "preserves E.164 input untouched" do
      assert {:ok, "+12025550100"} = PhoneFormatter.normalize("+12025550100")
    end

    test "parses +prefixed number with formatting to E.164" do
      assert {:ok, "+12025550100"} = PhoneFormatter.normalize("+1 202 555-0100")
    end

    test "parses international +prefixed number" do
      assert {:ok, "+442079460958"} = PhoneFormatter.normalize("+44 20 7946 0958")
    end

    test "leaves bare number unchanged (no region context)" do
      # Without a default region, we can't safely interpret what country this
      # 10-digit number belongs to. Returned trimmed-only.
      assert {:ok, "2025550100"} = PhoneFormatter.normalize("2025550100")
    end

    test "leaves formatted bare number trimmed-but-otherwise-unchanged" do
      assert {:ok, "(202) 555-0100"} = PhoneFormatter.normalize("(202) 555-0100")
    end

    test "trims whitespace around E.164 input" do
      assert {:ok, "+12025550100"} = PhoneFormatter.normalize("  +1 202 555 0100  ")
    end

    test "returns unparseable +prefixed input as-is" do
      # +0 is not a valid country code; libphonenumber rejects it.
      assert {:ok, "+0"} = PhoneFormatter.normalize("+0")
    end
  end

  describe "normalize/2 (with default region)" do
    test "parses bare US number to E.164 with US region" do
      assert {:ok, "+12025550100"} = PhoneFormatter.normalize("(202) 555-0100", "US")
    end

    test "parses bare UK number to E.164 with GB region" do
      assert {:ok, "+442079460958"} = PhoneFormatter.normalize("020 7946 0958", "GB")
    end

    test "parses bare French number to E.164 with FR region" do
      assert {:ok, "+33612345678"} = PhoneFormatter.normalize("06 12 34 56 78", "FR")
    end

    test "+prefixed number ignores the default region argument" do
      # The number is unambiguously German; passing "US" must not override.
      assert {:ok, "+4915155555555"} = PhoneFormatter.normalize("+49 151 5555 5555", "US")
    end

    test "explicit nil region is equivalent to normalize/1" do
      assert PhoneFormatter.normalize("(202) 555-0100") ==
               PhoneFormatter.normalize("(202) 555-0100", nil)
    end

    test "returns original on unparseable input with region" do
      assert {:ok, "garbage"} = PhoneFormatter.normalize("garbage", "US")
    end

    test "returns nil for nil regardless of region" do
      assert {:ok, nil} = PhoneFormatter.normalize(nil, "FR")
    end
  end

  describe "region_for_locale/1" do
    test "maps common locales to regions" do
      assert "US" = PhoneFormatter.region_for_locale("en")
      assert "FR" = PhoneFormatter.region_for_locale("fr")
      assert "DE" = PhoneFormatter.region_for_locale("de")
      assert "JP" = PhoneFormatter.region_for_locale("ja")
    end

    test "strips locale subtag" do
      assert "US" = PhoneFormatter.region_for_locale("en-GB")
      assert "FR" = PhoneFormatter.region_for_locale("fr_CA")
    end

    test "returns nil for unknown locales" do
      assert is_nil(PhoneFormatter.region_for_locale("xx"))
      assert is_nil(PhoneFormatter.region_for_locale(""))
      assert is_nil(PhoneFormatter.region_for_locale(nil))
    end
  end

  describe "supported_regions/1" do
    test "returns parser-supported regions with localized labels and calling codes" do
      regions = PhoneFormatter.supported_regions("en")

      # libphonenumber supports ~250 regions; we intersect with CLDR
      # country_codes so continents/aggregates are excluded.
      assert length(regions) > 200

      assert Enum.all?(regions, fn {code, label} ->
               is_binary(code) and byte_size(code) == 2 and
                 is_binary(label) and String.contains?(label, "(+")
             end)

      # Spot-check known entries
      assert Enum.find(regions, fn {code, _} -> code == "US" end) ==
               {"US", "United States (+1)"}

      assert {_code, label} = Enum.find(regions, fn {code, _} -> code == "GB" end)
      assert label =~ "United Kingdom"
      assert label =~ "+44"
    end

    test "returns localized names for non-English locales" do
      en = PhoneFormatter.supported_regions("en") |> Map.new()
      fr = PhoneFormatter.supported_regions("fr") |> Map.new()

      refute en["US"] == fr["US"]
      assert fr["US"] =~ "(+1)"
    end

    test "is sorted by label" do
      regions = PhoneFormatter.supported_regions("en")
      labels = Enum.map(regions, &elem(&1, 1))
      assert labels == Enum.sort(labels)
    end
  end

  describe "format/2" do
    test "e164 returns as-is" do
      assert "+12345678901" = PhoneFormatter.format("+12345678901", "e164")
    end

    test "raw returns as-is" do
      assert "+12345678901" = PhoneFormatter.format("+12345678901", "raw")
    end

    test "national formats US number" do
      assert "(234) 567-8901" = PhoneFormatter.format("+12345678901", "national")
    end

    test "international formats US number" do
      assert "+1 234-567-8901" = PhoneFormatter.format("+12345678901", "international")
    end

    test "national formats GB number" do
      assert "020 7946 0958" = PhoneFormatter.format("+442079460958", "national")
    end

    test "international formats GB number" do
      assert "+44 20 7946 0958" = PhoneFormatter.format("+442079460958", "international")
    end

    test "national formats FR number" do
      assert "01 23 45 67 89" = PhoneFormatter.format("+33123456789", "national")
    end

    test "international formats FR number" do
      assert "+33 1 23 45 67 89" = PhoneFormatter.format("+33123456789", "international")
    end

    test "national formats DE number" do
      assert "030 12345678" = PhoneFormatter.format("+493012345678", "national")
    end

    test "international formats DE number" do
      assert "+49 30 12345678" = PhoneFormatter.format("+493012345678", "international")
    end

    test "national formats JP number" do
      assert "090-1234-5678" = PhoneFormatter.format("+819012345678", "national")
    end

    test "international formats JP number" do
      assert "+81 90-1234-5678" = PhoneFormatter.format("+819012345678", "international")
    end

    test "national formats SA number" do
      assert "050 123 4567" = PhoneFormatter.format("+966501234567", "national")
    end

    test "international formats SA number" do
      assert "+966 50 123 4567" = PhoneFormatter.format("+966501234567", "international")
    end

    test "national leaves bare-number legacy value unchanged" do
      assert "5551234567" = PhoneFormatter.format("5551234567", "national")
    end

    test "international leaves bare-number legacy value unchanged" do
      assert "5551234567" = PhoneFormatter.format("5551234567", "international")
    end

    test "national leaves unparseable input unchanged" do
      assert "garbage" = PhoneFormatter.format("garbage", "national")
    end

    test "international leaves unparseable input unchanged" do
      assert "garbage" = PhoneFormatter.format("garbage", "international")
    end

    test "nil returns nil for every format" do
      for fmt <- ["e164", "national", "international", "raw"] do
        assert is_nil(PhoneFormatter.format(nil, fmt)), "expected nil for format=#{fmt}"
      end
    end

    test "empty string returns nil for every format" do
      for fmt <- ["e164", "national", "international", "raw"] do
        assert is_nil(PhoneFormatter.format("", fmt)), "expected nil for format=#{fmt}"
      end
    end
  end
end
