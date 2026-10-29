defmodule Kith.DAV.AddressQueryTest do
  use ExUnit.Case, async: true
  alias Kith.DAV.AddressQuery

  @card "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Jane\r\nTEL;TYPE=\"voice,home\";X-LABEL=\"a,b\":tel:+12025550123\r\nEND:VCARD\r\n"

  test "known TYPE comma lists match individual tokens even inside quotes" do
    assert AddressQuery.matches?(@card, filter("TYPE", "voice"))
    assert AddressQuery.matches?(@card, filter("TYPE", "home"))
    refute AddressQuery.matches?(@card, filter("TYPE", "work"))
  end

  test "unknown quoted parameter commas remain one client value" do
    assert AddressQuery.matches?(@card, filter("X-LABEL", "a,b"))
    refute AddressQuery.matches?(@card, filter("X-LABEL", "a"))
  end

  defp filter(parameter, text) do
    %{
      test: "allof",
      prop_filters: [
        %{
          name: "TEL",
          test: "allof",
          is_not_defined: false,
          text_matches: [],
          param_filters: [
            %{
              name: parameter,
              is_not_defined: false,
              text_match: %{
                text: text,
                match_type: "equals",
                collation: "i;ascii-casemap",
                negate: false
              }
            }
          ]
        }
      ]
    }
  end
end
