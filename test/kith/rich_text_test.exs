defmodule Kith.RichTextTest do
  use ExUnit.Case, async: true

  alias Kith.{Contacts.Note, Journal.Entry, RichText}

  @payload ~s|<div onclick="alert(1)">First <strong>bold</strong><br>Second</div><script>alert(2)</script><img src=x onerror="alert(3)"><a href="javascript:alert(4)">unsafe link</a>|

  test "both persistence boundaries retain Trix formatting and reject active HTML" do
    note = Note.changeset(%Note{}, %{body: @payload})

    journal =
      Entry.changeset(%Entry{}, %{content: @payload, occurred_at: DateTime.utc_now(:second)})

    assert note.valid?
    assert journal.valid?

    for html <- [
          Ecto.Changeset.get_change(note, :body),
          Ecto.Changeset.get_change(journal, :content)
        ] do
      assert html =~ "<div>First <strong>bold</strong><br />Second</div>"
      refute html =~ "onclick"
      refute html =~ "onerror"
      refute html =~ "javascript:"
      refute html =~ "<script"
    end
  end

  test "legacy struct bodies are sanitized at rendering without a database rewrite" do
    for html <- [%Note{body: @payload}.body, %Entry{content: @payload}.content] do
      assert {:safe, sanitized} = RichText.render(html)
      assert IO.iodata_to_binary(sanitized) == RichText.sanitize(html)
      refute IO.iodata_to_binary(sanitized) =~ "onerror"
    end

    assert RichText.render(nil) == {:safe, ""}
  end

  test "Trix strikethrough and code blocks retain formatting without active attributes" do
    html =
      "<del onclick='bad()'>old</del><pre style='color:red' onmouseover='bad()'>line 1\nline 2</pre>"

    expected = "<del>old</del><pre>line 1\nline 2</pre>"
    assert RichText.sanitize(html) == expected
    assert Phoenix.HTML.safe_to_string(RichText.render(html)) == expected

    for {schema, field} <- [{%Note{}, :body}, {%Entry{}, :content}] do
      changeset = schema.__struct__.changeset(schema, %{field => html})
      assert Ecto.Changeset.get_change(changeset, field) == expected
    end
  end
end
