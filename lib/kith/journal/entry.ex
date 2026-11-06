defmodule Kith.Journal.Entry do
  @moduledoc """
  Schema for journal entries.

  Journal entries are account-level (not contact-scoped) and support an optional
  mood tag and privacy flag. Private entries are visible only to their author.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @moods ~w(great good neutral bad awful)

  schema "journal_entries" do
    field(:title, :string)
    field(:content, :string)
    field(:occurred_at, :utc_datetime)
    field(:mood, :string)
    field(:is_private, :boolean, default: true)

    belongs_to(:account, Kith.Accounts.Account)
    belongs_to(:author, Kith.Accounts.User)

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the list of valid mood values."
  def moods, do: @moods

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:title, :content, :occurred_at, :mood, :is_private])
    |> validate_required([:content, :occurred_at])
    |> update_change(:content, &Kith.RichText.sanitize/1)
    |> then(fn cs ->
      if get_field(cs, :mood), do: validate_inclusion(cs, :mood, @moods), else: cs
    end)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:author_id)
  end
end
