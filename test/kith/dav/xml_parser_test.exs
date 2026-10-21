defmodule Kith.DAV.XMLParserTest do
  use ExUnit.Case, async: true

  alias Kith.DAV.XMLParser

  describe "parse_propfind/1" do
    test "CDV-04: malformed, non-XML and non-UTF-8 bodies are errors" do
      bodies = [
        ~s(<d:propfind xmlns:d="DAV:"><d:prop><d:getetag></d:prop>),
        "hello",
        ~s(<d:propfind xmlns:d="DAV:"></d:propfind>trailing),
        <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?><d:propfind xmlns:d=\"DAV:\">",
          "<d:prop><d:displayname>", 0xFF, 0xFE, "</d:displayname></d:prop></d:propfind>">>,
        ~s(<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]><d:propfind xmlns:d="DAV:"/>)
      ]

      for body <- bodies do
        assert {:error, :invalid_xml} = XMLParser.parse_propfind(body), inspect(body)
      end
    end

    test "CDV-04: billion-laughs internal entities are refused, not expanded" do
      body = """
      <?xml version="1.0"?>
      <!DOCTYPE d:propfind [
        <!ENTITY lol "lol">
        <!ENTITY lol1 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        <!ENTITY lol2 "&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;">
        <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
        <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
        <!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">
        <!ENTITY lol6 "&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;">
        <!ENTITY lol7 "&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;">
        <!ENTITY lol8 "&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;">
        <!ENTITY lol9 "&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;">
      ]>
      <d:propfind xmlns:d="DAV:"><d:prop><d:displayname>&lol9;</d:displayname></d:prop></d:propfind>
      """

      # No wall-clock bound: an expanding parser would blow the ExUnit timeout
      # (or memory) rather than return, which also fails the test.
      assert XMLParser.parse_propfind(body) == {:error, :invalid_xml}
      assert {:error, :invalid_xml} = XMLParser.parse_proppatch(body)
    end

    test "CDV-04: external SYSTEM entities are refused, not fetched" do
      body = """
      <?xml version="1.0"?>
      <!DOCTYPE d:propfind [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
      <d:propfind xmlns:d="DAV:"><d:prop><d:displayname>&xxe;</d:displayname></d:prop></d:propfind>
      """

      assert {:error, :invalid_xml} = XMLParser.parse_propfind(body)
      assert {:error, :invalid_xml} = XMLParser.parse_proppatch(body)
    end

    test "CDV-04: empty and whitespace-only bodies are allprop" do
      assert {:ok, :allprop} = XMLParser.parse_propfind("")
      assert {:ok, :allprop} = XMLParser.parse_propfind("  \r\n")
    end

    test "CDV-05: allprop and propname are recognised whatever the prefix" do
      for kind <- ["allprop", "propname"] do
        expected = {:ok, String.to_existing_atom(kind)}

        assert XMLParser.parse_propfind(~s(<d:propfind xmlns:d="DAV:"><d:#{kind}/></d:propfind>)) ==
                 expected

        assert XMLParser.parse_propfind(~s(<A:propfind xmlns:A="DAV:"><A:#{kind}/></A:propfind>)) ==
                 expected

        assert XMLParser.parse_propfind(~s(<propfind xmlns="DAV:"><#{kind}/></propfind>)) ==
                 expected
      end
    end

    test "CDV-05: requested props are matched by namespace and local name, not substring" do
      apple = """
      <?xml version="1.0" encoding="UTF-8"?>
      <A:propfind xmlns:A="DAV:" xmlns:B="urn:ietf:params:xml:ns:carddav" xmlns:C="http://calendarserver.org/ns/">
        <A:prop><A:sync-token/><C:getctag/><B:addressbook-home-set/></A:prop>
      </A:propfind>
      """

      assert {:ok, {:prop, props}} = XMLParser.parse_propfind(apple)
      assert Enum.sort(props) == [:addressbook_home_set, :getctag, :sync_token]

      default_ns = """
      <propfind xmlns="DAV:"><prop>
        <current-user-principal/>
        <addressbook-home-set xmlns="urn:ietf:params:xml:ns:carddav"/>
      </prop></propfind>
      """

      assert {:ok, {:prop, props}} = XMLParser.parse_propfind(default_ns)
      assert Enum.sort(props) == [:addressbook_home_set, :current_user_principal]

      substring = """
      <d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:o="urn:owner-getctag">
        <d:prop><card:supported-address-data/></d:prop>
      </d:propfind>
      """

      assert {:ok, {:prop, [:supported_address_data]}} = XMLParser.parse_propfind(substring)

      wrong_ns = ~s(<d:propfind xmlns:d="DAV:"><d:prop><d:getctag/></d:prop></d:propfind>)
      assert {:ok, {:prop, props}} = XMLParser.parse_propfind(wrong_ns)
      refute :getctag in props
    end

    test "CDV-06: unknown props are returned with their namespace" do
      body = """
      <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><x:bogus xmlns:x="urn:x"/><plain xmlns=""/></d:prop></d:propfind>
      """

      assert {:ok, {:prop, [:getetag, {"urn:x", "bogus"}, {"", "plain"}]}} =
               XMLParser.parse_propfind(body)
    end

    test "CDV-05: a body whose root is not DAV:propfind is an error" do
      assert {:error, :invalid_xml} =
               XMLParser.parse_propfind(~s(<x:propfind xmlns:x="urn:x"><x:allprop/></x:propfind>))
    end
  end

  describe "parse_proppatch/1" do
    test "CDV-05: returns the props of set and remove instructions, any prefix" do
      body = """
      <A:propertyupdate xmlns:A="DAV:">
        <A:set><A:prop><A:displayname>X</A:displayname></A:prop></A:set>
        <A:remove><A:prop><A:getetag/></A:prop></A:remove>
      </A:propertyupdate>
      """

      assert {:ok, [:displayname, :getetag]} = XMLParser.parse_proppatch(body)
      assert {:error, :invalid_xml} = XMLParser.parse_proppatch("<A:propertyupdate")
    end
  end
end
