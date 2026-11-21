defmodule Kith.Accounts.OptionalFeatures do
  @moduledoc "Effective workspace settings for optional Journal and contact history."

  alias Kith.Accounts

  @definitions [
    {"journal", "Journal", "Write and browse personal journal entries."},
    {"calls", "Calls", "Log phone calls with contacts."},
    {"life_events", "Life Events", "Track contact milestones and manage Life Event Types."},
    {"activities", "Activities", "Log shared activities and manage Activity Types."},
    {"tasks", "Tasks", "Track and complete tasks for contacts."},
    {"gifts", "Gifts", "Track gifts given to or received from contacts."},
    {"conversations", "Conversations", "Track conversations and their messages."}
  ]
  @keys Enum.map(@definitions, &elem(&1, 0))
  @timeline_features %{
    call: "calls",
    life_event: "life_events",
    activity: "activities",
    task: "tasks",
    gift: "gifts",
    conversation: "conversations"
  }

  def monica_keys, do: ~w(calls activities gifts tasks conversations)
  def monica_skip_key(key), do: "#{key}_feature_disabled"

  def definitions, do: @definitions
  def keys, do: @keys
  def known?(key), do: key in @keys
  def enabled?(account, key), do: Accounts.module_enabled?(account, key)
  def effective(account), do: Map.new(@keys, &{&1, enabled?(account, &1)})
  def topic(account_id), do: "optional_features:#{account_id}"

  def label(key) do
    {^key, label, _} = List.keyfind(@definitions, key, 0)
    label
  end

  def available_types(account, types) do
    Enum.filter(types, fn type ->
      case @timeline_features[type] do
        nil -> true
        feature -> enabled?(account, feature)
      end
    end)
  end
end
