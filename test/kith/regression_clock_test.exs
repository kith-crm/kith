defmodule Kith.RegressionClockTest do
  use ExUnit.Case, async: true

  alias Kith.RegressionClock

  for wall_time <- [~U[2026-11-05 22:59:59Z], ~U[2026-11-05 23:13:23Z], ~U[2026-11-05 23:59:59Z]] do
    test "expired snooze is eligible at fixture dispatch when prepared at #{wall_time}" do
      # The CLI payload round trip must retain one clock even after 23:00 UTC.
      frozen = RegressionClock.capture(DateTime.to_date(unquote(Macro.escape(wall_time))))
      args = %{"dispatch_at" => DateTime.to_iso8601(frozen)}

      assert DateTime.compare(RegressionClock.expired_snooze_at(args), frozen) == :lt
      assert DateTime.diff(frozen, RegressionClock.expired_snooze_at(args)) == 60
    end
  end

  test "subsequent CLI calls retain the captured date across midnight" do
    frozen = RegressionClock.capture(~D[2026-11-05])
    args = Jason.decode!(Jason.encode!(%{dispatch_at: frozen}))

    assert RegressionClock.now(args) == ~U[2026-11-05 23:00:00Z]
    assert RegressionClock.expired_snooze_at(args) == ~U[2026-11-05 22:59:00Z]

    assert DateTime.compare(RegressionClock.expired_snooze_at(args), ~U[2026-11-06 00:00:00Z]) ==
             :lt
  end
end
