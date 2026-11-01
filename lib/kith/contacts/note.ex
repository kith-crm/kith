defmodule Kith.Contacts.Note do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notes" do
    field :body, :string
    field :favorite, :boolean, default: false
    field :is_private, :boolean, default: false

    belongs_to :contact, Kith.Contacts.Contact
    belongs_to :account, Kith.Accounts.Account
    belongs_to :author, Kith.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:body, :favorite, :is_private, :contact_id, :account_id, :author_id])
    |> validate_required([:body])
    |> sanitize_body()
  end

  defp sanitize_body(changeset) do
    case get_change(changeset, :body) do
      nil ->
        changeset

      body ->
        sanitized = HtmlSanitizeEx.Scrubber.scrub(body, __MODULE__.Scrubber)
        put_change(changeset, :body, sanitized)
    end
  end

  defmodule Scrubber do
    @moduledoc false
    require HtmlSanitizeEx.Scrubber.Meta
    alias HtmlSanitizeEx.Scrubber.Meta

    Meta.remove_cdata_sections_before_scrub()
    Meta.strip_comments()

    Meta.allow_tag_with_uri_attributes("a", ["href"], ["http", "https", "mailto"])
    Meta.allow_tag_with_these_attributes("a", ["target", "rel"])

    # Trix serializes paragraph blocks as divs. Keep their boundaries while
    # rejecting all attributes, including style and event handlers.
    Meta.allow_tag_with_these_attributes("div", [])
    Meta.allow_tag_with_these_attributes("p", [])
    Meta.allow_tag_with_these_attributes("br", [])
    Meta.allow_tag_with_these_attributes("strong", [])
    Meta.allow_tag_with_these_attributes("em", [])
    Meta.allow_tag_with_these_attributes("ul", [])
    Meta.allow_tag_with_these_attributes("ol", [])
    Meta.allow_tag_with_these_attributes("li", [])
    Meta.allow_tag_with_these_attributes("h1", [])
    Meta.allow_tag_with_these_attributes("h2", [])
    Meta.allow_tag_with_these_attributes("h3", [])
    Meta.allow_tag_with_these_attributes("h4", [])
    Meta.allow_tag_with_these_attributes("h5", [])
    Meta.allow_tag_with_these_attributes("h6", [])
    Meta.allow_tag_with_these_attributes("blockquote", [])

    @before_compile HtmlSanitizeEx.ScrubberCompiler
  end
end
