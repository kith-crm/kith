defmodule Kith.Accounts.ReminderRulesSeedingTest do
  use Kith.DataCase, async: true

  alias Kith.{Accounts, Reminders}

  test "email signup seeds the 0/7/30-day reminder rules" do
    {:ok, user} =
      Accounts.register_user(%{
        email: "seed#{System.unique_integer([:positive])}@example.com",
        password: "hello world!!",
        name: "Seed",
        tos_accepted: true
      })

    assert Enum.map(Reminders.list_reminder_rules(user.account_id), & &1.days_before) == [
             0,
             7,
             30
           ]
  end
end
