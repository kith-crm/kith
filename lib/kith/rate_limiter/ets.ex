defmodule Kith.RateLimiter.ETS do
  @moduledoc false
  use Hammer, backend: :ets, algorithm: :fix_window
end
