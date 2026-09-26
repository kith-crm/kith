defmodule Kith.Workers.ReminderDispatcher do
  @moduledoc "Hourly cron entry point for `Kith.Reminders.Dispatcher.run/1`."

  use Oban.Worker, queue: :reminders, unique: [period: 3_000]

  alias Kith.Reminders.Dispatcher

  @impl Oban.Worker
  def perform(_job), do: Dispatcher.run(DateTime.utc_now())
end
