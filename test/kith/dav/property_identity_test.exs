defmodule Kith.DAV.PropertyIdentityTest do
  use ExUnit.Case, async: true
  alias Kith.DAV.PropertyIdentity

  test "source tables reject conflicting indexes in parsed and persisted properties" do
    for version <- ["3.0", "4.0"] do
      {:ok, document} =
        Kith.VCard.Document.parse(
          "BEGIN:VCARD\r\nVERSION:#{version}\r\nFN:Contact\r\n" <>
            "CLIENTPIDMAP:1;https://example.org/one\r\n" <>
            "CLIENTPIDMAP:1;https://example.org/two\r\nEND:VCARD\r\n"
        )

      assert {:error, :ambiguous_property_identity} =
               PropertyIdentity.sources(document.properties)

      persisted =
        Enum.map(document.properties, fn property ->
          %{"normalized_name" => property.normalized_name, "value" => property.value}
        end)

      assert {:error, :ambiguous_property_identity} = PropertyIdentity.sources(persisted)
    end
  end

  test "equivalent duplicate sources and reordered PID lists share identity" do
    for version <- ["3.0", "4.0"] do
      {:ok, document} =
        Kith.VCard.Document.parse(
          "BEGIN:VCARD\r\nVERSION:#{version}\r\nFN:Contact\r\n" <>
            "CLIENTPIDMAP:1;HTTPS://EXAMPLE.COM/%7eUser\r\n" <>
            "CLIENTPIDMAP:1;https://example.com/~User\r\n" <>
            "CLIENTPIDMAP:7;https://example.com/~User\r\n" <>
            "EMAIL;PID=2.1,1.7,2.7:same@example.org\r\nEND:VCARD\r\n"
        )

      assert {:ok, sources} = PropertyIdentity.sources(document.properties)
      property = List.last(document.properties)

      assert PropertyIdentity.pids(property, sources) ==
               MapSet.new([
                 {"https://example.com/~User", "1"},
                 {"https://example.com/~User", "2"}
               ])
    end
  end

  test "UUID URN casing and supported bare forms share one source identity" do
    canonical = "urn:uuid:a1111111-1111-4111-8111-111111111111"
    assert PropertyIdentity.source("URN:UUID:A1111111-1111-4111-8111-111111111111") == canonical
    assert PropertyIdentity.source("A1111111-1111-4111-8111-111111111111") == canonical
  end

  test "normalizes URI scheme, host and unreserved escapes without changing reserved paths" do
    assert PropertyIdentity.source("HTTPS://EXAMPLE.COM/%7eUser/%2f?x=%41#%7a") ==
             "https://example.com/~User/%2F?x=A#z"

    assert PropertyIdentity.source("https://%65XAMPLE.com/%7e") == "https://example.com/~"

    refute PropertyIdentity.source("https://example.com/User") ==
             PropertyIdentity.source("https://example.com/user")

    refute PropertyIdentity.source("https://example.com/a%2Fb") ==
             PropertyIdentity.source("https://example.com/a/b")
  end
end
