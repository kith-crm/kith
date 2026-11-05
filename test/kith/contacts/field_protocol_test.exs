defmodule Kith.Contacts.FieldProtocolTest do
  use ExUnit.Case, async: true

  alias Kith.Contacts.FieldProtocol

  test "normalizes protocol tokens" do
    assert FieldProtocol.normalize(" TEL:// ") == "tel"
    assert FieldProtocol.normalize("mailto:") == "mailto"
    assert FieldProtocol.normalize(" HTTPS ") == "https"
    assert FieldProtocol.normalize("custom:") == "custom"
    assert FieldProtocol.normalize(nil) == nil
  end
end
