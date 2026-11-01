defmodule Kith.RichText do
  @moduledoc """
  The shared Trix HTML boundary for persisted and legacy rich text.

  Every render is scrubbed again, so rows written before input sanitization
  cannot bypass the same narrow formatting and URL allowlist used on writes.
  """

  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(nil), do: ""

  def sanitize(html) when is_binary(html) do
    HtmlSanitizeEx.Scrubber.scrub(html, Kith.Contacts.Note.Scrubber)
  end

  @spec render(String.t() | nil) :: Phoenix.HTML.safe()
  def render(html) do
    html
    |> sanitize()
    |> Phoenix.HTML.raw()
  end
end
