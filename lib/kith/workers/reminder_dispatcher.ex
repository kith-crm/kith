defmodule Kith.Workers.ReminderDispatcher do
  @moduledoc "Hourly cron entry point for `Kith.Reminders.Dispatcher.run/1`."

  use Oban.Worker, queue: :reminders, unique: [period: 3_000]

  @impl Oban.Worker
  def perform(_job), do: Kith.Reminders.Dispatcher.run(DateTime.utc_now())
end
