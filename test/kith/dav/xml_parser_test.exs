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

    test "CDV-04: empty and whitespace-only bodies are allprop" do
      assert {:ok, :allprop} = XMLParser.parse_propfind("")
      assert {:ok, :allprop} = XMLParser.parse_propfind("  \r\n")
    end
  end
end
