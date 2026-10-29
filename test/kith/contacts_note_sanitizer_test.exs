defmodule Kith.ContactsNoteSanitizerTest do
  use ExUnit.Case, async: true
  alias Kith.Contacts.Note

  test "server persistence boundary keeps formatting and rejects editor payloads" do
    body =
      ~s|<p><strong>Kept bold</strong> <a href="https://example.com">safe link</a></p>| <>
        ~s|<span data-trix-attachment='{}' data-trix-attributes='{"href":"javascript:alert(1)"}'>payload text</span>| <>
        ~s|<a href="javascript:alert(1)" onclick="alert(2)">bad link</a><script>alert(3)</script><img src=x onerror=alert(4)>|

    changeset = Note.changeset(%Note{}, %{body: body})
    assert changeset.valid?
    sanitized = Ecto.Changeset.get_change(changeset, :body)
    assert sanitized =~ "<strong>Kept bold</strong>"
    assert sanitized =~ ~s|href="https://example.com"|
    assert sanitized =~ "payload text"
    refute sanitized =~ "javascript:"
    refute sanitized =~ "onclick"
    refute sanitized =~ "onerror"
    refute sanitized =~ "<script"
    refute sanitized =~ "data-trix"
  end

  test "Trix block and line boundaries survive persistence without retaining unsafe attributes" do
    body =
      ~s|<div class="trix-block" style="position:fixed" onclick="alert(1)">First paragraph</div>| <>
        ~s|<div data-trix-id="2">Second paragraph<br>Next line</div>|

    changeset = Note.changeset(%Note{}, %{body: body})
    assert changeset.valid?

    assert Ecto.Changeset.get_change(changeset, :body) ==
             "<div>First paragraph</div><div>Second paragraph<br />Next line</div>"
  end

  test "many siblings retain allowed text without enabling HTML5 or CSS features" do
    body =
      String.duplicate("<p>kept</p>", 1_000) <>
        ~s|<form id="hijack"></form><meta http-equiv="refresh" content="0;url=https://evil.test"><object data="https://evil.test"></object><p style="color:red">plain</p>|

    changeset = Note.changeset(%Note{}, %{body: body})
    sanitized = Ecto.Changeset.get_change(changeset, :body)
    assert sanitized == String.duplicate("<p>kept</p>", 1_000) <> "<p>plain</p>"
  end
end
