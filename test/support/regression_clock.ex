defmodule Kith.RegressionClock do
  @moduledoc "A scenario clock carried across the browser harness's separate CLI calls."

  def capture(%Date{} = today), do: DateTime.new!(today, ~T[23:00:00], "Etc/UTC")

  def now(%{"dispatch_at" => timestamp}) do
    {:ok, now, 0} = DateTime.from_iso8601(timestamp)
    now
  end

  def expired_snooze_at(args), do: args |> now() |> DateTime.add(-60, :second)
end
