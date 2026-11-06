defmodule Kith.DAV.XMLBuilderTest do
  use ExUnit.Case, async: true

  alias Kith.DAV.XMLBuilder

  import SweetXml

  test "dynamic DAV text and href values remain text rather than XML elements" do
    payload = ~s|</d:displayname><script xmlns="http://www.w3.org/1999/xhtml">alert(1)</script>&"|
    href = "/dav/addressbooks/default/a?<script>&\""

    xml =
      XMLBuilder.multistatus([
        XMLBuilder.response(href, [XMLBuilder.propstat([XMLBuilder.displayname(payload)])])
      ])

    assert xpath(xml, ~x"string(//*[local-name()='displayname'])"s) == payload
    assert xpath(xml, ~x"string(//*[local-name()='href'])"s) == href
    assert xpath(xml, ~x"count(//*[local-name()='script'])"i) == 0
  end

  test "vCard CDATA delimiters cannot create sibling XML elements" do
    vcard = ~s|BEGIN:VCARD\r\nNOTE:]]><script>alert(1)</script>\r\nEND:VCARD\r\n|

    xml =
      XMLBuilder.multistatus([
        XMLBuilder.response("/dav/addressbooks/default/a.vcf", [
          XMLBuilder.propstat([XMLBuilder.address_data(vcard)])
        ])
      ])

    assert xpath(xml, ~x"string(//*[local-name()='address-data'])"s) == vcard
    assert xpath(xml, ~x"count(//*[local-name()='script'])"i) == 0
  end

  describe "address_data/1" do
    test "wraps vCard in CDATA section" do
      vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Test\r\nEND:VCARD\r\n"
      result = XMLBuilder.address_data(vcard)

      assert result == "<card:address-data><![CDATA[#{vcard}]]></card:address-data>"
    end

    test "preserves CRLF line endings inside CDATA" do
      vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nBDAY:1990-06-15\r\nEND:VCARD\r\n"
      result = XMLBuilder.address_data(vcard)

      assert result =~ "\r\n"
      refute result =~ "&amp;"
    end

    test "escapes ]]> in vCard content to prevent CDATA injection" do
      vcard = "BEGIN:VCARD\r\nNOTE:Has ]]> in it\r\nEND:VCARD\r\n"
      result = XMLBuilder.address_data(vcard)

      refute result =~ "NOTE:Has ]]>"
      assert result =~ "]]]]><![CDATA[>"
    end
  end
end
