defmodule Kith.Contacts.NoteTest do
  use ExUnit.Case, async: true
  alias Kith.Contacts.Note

  test "renders the supported rich text vocabulary" do
    html =
      ~s|<div><strong>bold</strong><em>italic</em><del>strike</del><pre>code</pre><h1>heading</h1><h2>two</h2><h3>three</h3><h4>four</h4><h5>five</h5><h6>six</h6><blockquote>quote</blockquote><ul><li>bullet</li></ul><ol><li>number</li></ol><a href="https://example.com">link</a><br>line</div>|

    rendered = Note.render_body(html)

    for expected <- [
          "<strong>bold</strong>",
          "<em>italic</em>",
          "<del>strike</del>",
          "<pre>code</pre>",
          "<h1>heading</h1>",
          "<h2>two</h2>",
          "<h3>three</h3>",
          "<h4>four</h4>",
          "<h5>five</h5>",
          "<h6>six</h6>",
          "<blockquote>quote</blockquote>",
          "<ul><li>bullet</li></ul>",
          "<ol><li>number</li></ol>",
          ~s|<a href="https://example.com">link</a>|,
          "<br />line"
        ] do
      assert rendered =~ expected
    end
  end

  test "legacy text preserves literal characters and blank lines" do
    assert Note.render_body("first\n\nsecond") == "first\n\nsecond"
    assert Note.render_body("x < 3 & y > 1") == "x &lt; 3 &amp; y &gt; 1"

    assert Note.changeset(%Note{}, %{body: "x < 3 & y > 1"}).changes.body ==
             "x &lt; 3 &amp; y &gt; 1"

    assert Note.render_body("&lt;script&gt;alert(1)&lt;/script&gt;") ==
             "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  test "rendering and editing escaped imports keeps markup inert" do
    body = "&lt;img src=x onerror=evil()&gt;\n**literal punctuation**"
    saved = Note.changeset(%Note{}, %{body: body}).changes.body
    assert saved == body
    assert Note.render_body(saved) == body
    refute Note.render_body(saved) =~ "<img"
    refute Note.render_body(saved) =~ "<strong>"
  end

  test "legacy malicious markup cannot bypass the shared sanitizer" do
    html =
      ~s|<script>alert(1)</script><object data="bad"></object><p onclick="evil()">safe</p><a href="javascript:evil()">link</a>|

    rendered = Note.render_body(html)
    refute rendered =~ "<script"
    refute rendered =~ "<object"
    refute rendered =~ "onclick"
    refute rendered =~ "javascript:"
    assert rendered =~ "<p>safe</p>"
  end
end
