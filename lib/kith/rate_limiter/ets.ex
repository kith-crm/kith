defmodule Kith.RateLimiter.ETS do
  @moduledoc false
  use Hammer, backend: :ets, algorithm: :fix_window
  # Fixed-window entries are {{key, window}, count, expires_at}. Remove all
  # windows for this key, matching the authentication reset across backends.
  def reset(key), do: :ets.match_delete(__MODULE__, {{key, :_}, :_, :_})
end
