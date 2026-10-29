defmodule Kith.DAV.XMLParserTest do
  use ExUnit.Case, async: true

  alias Kith.DAV.XMLParser

  describe "parse_propfind/1" do
    test "malformed, non-XML and non-UTF-8 bodies are errors" do
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

    test "billion-laughs internal entities are refused, not expanded" do
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

    test "external SYSTEM entities are refused, not fetched" do
      body = """
      <?xml version="1.0"?>
      <!DOCTYPE d:propfind [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
      <d:propfind xmlns:d="DAV:"><d:prop><d:displayname>&xxe;</d:displayname></d:prop></d:propfind>
      """

      assert {:error, :invalid_xml} = XMLParser.parse_propfind(body)
      assert {:error, :invalid_xml} = XMLParser.parse_proppatch(body)
    end

    test "empty and whitespace-only bodies are allprop" do
      assert {:ok, :allprop} = XMLParser.parse_propfind("")
      assert {:ok, :allprop} = XMLParser.parse_propfind("  \r\n")
    end

    test "allprop and propname are recognised whatever the prefix" do
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

    test "requires one selector and permits include only with allprop" do
      for selectors <- [
            "",
            "<d:undefined/>",
            "<x:prop xmlns:x=\"urn:x\"/>",
            "<d:allprop/><d:propname/>",
            "<d:allprop/><d:prop/>",
            "<d:prop/><d:propname/>",
            "<d:prop/><d:prop/>",
            "<d:allprop/><d:allprop/>",
            "<d:propname/><d:propname/>",
            "<d:include/>",
            "<d:prop/><d:include/>",
            "<d:propname/><d:include/>",
            "<d:allprop/><d:include/><d:include/>",
            "<x:extension xmlns:x=\"urn:x\"><d:allprop/></x:extension>"
          ] do
        body = ~s(<d:propfind xmlns:d="DAV:">#{selectors}</d:propfind>)
        assert {:error, :invalid_xml} = XMLParser.parse_propfind(body), selectors
      end
    end

    test "property requests and selectors reject text values" do
      for selectors <- [
            "<d:prop><d:displayname>value</d:displayname></d:prop>",
            "<d:allprop>value</d:allprop>",
            "<d:prop>value</d:prop>",
            "<d:allprop/><d:include><d:displayname>value</d:displayname></d:include>",
            "value<d:propname/>"
          ] do
        body = ~s(<d:propfind xmlns:d="DAV:">#{selectors}</d:propfind>)
        assert {:error, :invalid_xml} = XMLParser.parse_propfind(body), selectors
      end
    end

    test "ignores extension attributes and subtrees alongside a valid selector" do
      body = """
      <d:propfind xmlns:d="DAV:" xmlns:x="urn:x" x:flag="yes">
        <x:extension><d:propname/><d:prop><d:getetag/></d:prop></x:extension>
        <d:allprop x:flag="yes"/><d:undefined/>
      </d:propfind>
      """

      assert {:ok, :allprop} = XMLParser.parse_propfind(body)

      assert {:ok, {:prop, []}} =
               XMLParser.parse_propfind(~s(<propfind xmlns="DAV:"><prop/></propfind>))
    end

    test "allprop include preserves requested property namespaces in either order" do
      for selectors <- [
            "<d:allprop/><d:include><d:getetag/><x:extra/></d:include>",
            "<d:include><d:getetag/><x:extra/></d:include><d:allprop/>"
          ] do
        body = ~s(<d:propfind xmlns:d="DAV:" xmlns:x="urn:x">#{selectors}</d:propfind>)
        assert {:ok, {:allprop, [:getetag, {"urn:x", "extra"}]}} = XMLParser.parse_propfind(body)
      end
    end

    test "requested props are matched by namespace and local name, not substring" do
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

    test "unknown props are returned with their namespace" do
      body = """
      <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><x:bogus xmlns:x="urn:x"/><plain xmlns=""/></d:prop></d:propfind>
      """

      assert {:ok, {:prop, [:getetag, {"urn:x", "bogus"}, {"", "plain"}]}} =
               XMLParser.parse_propfind(body)
    end

    test "a body whose root is not DAV:propfind is an error" do
      assert {:error, :invalid_xml} =
               XMLParser.parse_propfind(~s(<x:propfind xmlns:x="urn:x"><x:allprop/></x:propfind>))
    end
  end

  describe "principal report parsing" do
    test "parses nested namespace-aware property expansion" do
      body =
        ~s(<expand-property xmlns="DAV:"><property name="owner"><property name="displayname"/><property name="custom" namespace="urn:client"/></property></expand-property>)

      assert {:ok,
              {:principal_report,
               %{
                 type: :expand_property,
                 properties: [
                   %{
                     property: :owner,
                     children: [
                       %{property: :displayname, children: []},
                       %{property: {"urn:client", "custom"}, children: []}
                     ]
                   }
                 ]
               }}} = XMLParser.parse_report(body)
    end

    test "requires principal report selector cardinality and valid property shapes" do
      for body <- [
            ~s(<principal-match xmlns="DAV:"/>),
            ~s(<principal-match xmlns="DAV:"><self/><principal-property><owner/></principal-property></principal-match>),
            ~s(<principal-match xmlns="DAV:"><self/><self/></principal-match>),
            ~s(<principal-match xmlns="DAV:"><principal-property><owner/><group/></principal-property></principal-match>),
            ~s(<principal-match xmlns="DAV:"><self/><prop><displayname>value</displayname></prop></principal-match>),
            ~s(<principal-property-search xmlns="DAV:"/>),
            ~s(<principal-property-search xmlns="DAV:"><property-search><prop><displayname/></prop></property-search></principal-property-search>),
            ~s(<principal-property-search xmlns="DAV:"><property-search><prop/><match>x</match></property-search></principal-property-search>),
            ~s(<principal-property-search xmlns="DAV:"><property-search><prop><displayname/></prop><match><nested/></match></property-search></principal-property-search>),
            ~s(<acl-principal-prop-set xmlns="DAV:"><prop/><prop/></acl-principal-prop-set>),
            ~s(<principal-search-property-set xmlns="DAV:"><prop/></principal-search-property-set>),
            ~s(<expand-property xmlns="DAV:"><property/></expand-property>),
            ~s(<expand-property xmlns="DAV:"><property name="bad:name"/></expand-property>),
            ~s(<expand-property xmlns="DAV:"><property name="owner">text</property></expand-property>)
          ] do
        assert {:error, :invalid_xml} = XMLParser.parse_report(body), body
      end
    end

    test "extension subtrees cannot add search criteria or expansion instructions" do
      assert {:ok, {:principal_report, %{type: :expand_property, properties: []}}} =
               XMLParser.parse_report(
                 ~s(<expand-property xmlns="DAV:" xmlns:x="urn:client"><x:extra><property name="owner"/></x:extra></expand-property>)
               )

      assert {:error, :invalid_xml} =
               XMLParser.parse_report(
                 ~s(<principal-match xmlns="DAV:" xmlns:x="urn:client"><x:extra><self/></x:extra></principal-match>)
               )
    end

    test "ACL requests reject malformed ACEs and wrong root elements" do
      assert :ok = XMLParser.parse_acl(~s(<acl xmlns="DAV:"/>))

      assert :ok =
               XMLParser.parse_acl(
                 ~s(<acl xmlns="DAV:"><ace><principal><href>/dav/principals/roles/admin/</href></principal><grant><privilege><read/></privilege></grant></ace></acl>)
               )

      for body <- [
            ~s(<acl xmlns="urn:client"/>),
            ~s(<acl xmlns="DAV:"><ace/></acl>),
            ~s(<acl xmlns="DAV:"><ace><principal><all/></principal><grant/><deny/></ace></acl>),
            ~s(<acl xmlns="DAV:"><ace><principal><all/><self/></principal><grant><privilege><read/></privilege></grant></ace></acl>),
            ~s(<acl xmlns="DAV:"><ace><principal><all/></principal><grant><privilege><read/><write/></privilege></grant></ace></acl>)
          ] do
        assert {:error, :invalid_xml} = XMLParser.parse_acl(body), body
      end
    end
  end

  describe "parse_proppatch/1" do
    test "retains the actions and values of set and remove instructions, any prefix" do
      body = """
      <A:propertyupdate xmlns:A="DAV:">
        <A:set><A:prop><A:displayname>X</A:displayname></A:prop></A:set>
        <A:remove><A:prop><A:getetag/></A:prop></A:remove>
      </A:propertyupdate>
      """

      assert {:ok,
              [
                %{action: :set, property: :displayname, value: %{text: "X"}},
                %{action: :remove, property: :getetag, value: %{text: ""}}
              ]} = XMLParser.parse_proppatch(body)

      assert {:error, :invalid_xml} = XMLParser.parse_proppatch("<A:propertyupdate")
    end

    test "preserves repeated properties, namespaces and mixed XML value order" do
      body = """
      <propertyupdate xmlns="DAV:" xmlns:x="urn:client" xmlns:y="urn:other">
        <set><prop><x:label x:flag="one" y:flag="two">before<x:child/>after</x:label></prop></set>
        <remove><prop><x:label/></prop></remove>
        <set><prop><x:label>replacement</x:label></prop></set>
      </propertyupdate>
      """

      assert {:ok, [first, second, third]} = XMLParser.parse_proppatch(body)

      assert Enum.map([first, second, third], & &1.property) ==
               List.duplicate({"urn:client", "label"}, 3)

      assert Enum.map([first, second, third], & &1.action) == [:set, :remove, :set]

      assert [{:text, "before"}, {:element, %{ns: "urn:client", name: "child"}}, {:text, "after"}] =
               first.value.content

      assert %{ns: "urn:client", name: "flag", value: "one"} in first.value.attributes
      assert %{ns: "urn:other", name: "flag", value: "two"} in first.value.attributes
      assert third.value.text == "replacement"
    end

    test "rejects missing instructions, invalid containers, direct text and nonempty removals" do
      for instructions <- [
            "",
            "<prop><displayname/></prop>",
            "<set/>",
            "<set><prop/></set>",
            "<set><prop><displayname/></prop><prop><getetag/></prop></set>",
            "text<set><prop><displayname/></prop></set>",
            "<set>text<prop><displayname/></prop></set>",
            "<set><prop>text<displayname/></prop></set>",
            "<remove><prop><displayname>value</displayname></prop></remove>",
            "<remove><prop><displayname><child/></displayname></prop></remove>"
          ] do
        body = ~s(<propertyupdate xmlns="DAV:">#{instructions}</propertyupdate>)
        assert {:error, :invalid_xml} = XMLParser.parse_proppatch(body), instructions
      end
    end

    test "extension subtrees cannot inject instructions" do
      body = """
      <d:propertyupdate xmlns:d="DAV:" xmlns:x="urn:extension">
        <x:extension><d:set><d:prop><d:getetag/></d:prop></d:set></x:extension>
        <d:set><x:extension><d:prop><d:getetag/></d:prop></x:extension><d:prop><d:displayname>X</d:displayname></d:prop></d:set>
      </d:propertyupdate>
      """

      assert {:ok, [%{action: :set, property: :displayname}]} = XMLParser.parse_proppatch(body)

      assert {:error, :invalid_xml} =
               XMLParser.parse_proppatch(
                 ~s(<propertyupdate xmlns="DAV:" xmlns:x="urn:x"><x:extension><set><prop><getetag/></prop></set></x:extension></propertyupdate>)
               )
    end
  end

  test "namespaced expansion attributes cannot supply required DAV instructions" do
    assert {:error, :invalid_xml} =
             XMLParser.parse_report(
               ~s(<d:expand-property xmlns:d="DAV:" xmlns:x="urn:extension"><d:property x:name="owner"/></d:expand-property>)
             )

    assert {:ok, {:principal_report, %{properties: [%{property: :owner}]}}} =
             XMLParser.parse_report(
               ~s(<d:expand-property xmlns:d="DAV:" xmlns:x="urn:extension"><d:property name="owner" x:namespace="urn:extension"/></d:expand-property>)
             )
  end
end
