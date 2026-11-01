defmodule Kith.Cache.Store do
  @moduledoc false

  use Nebulex.Cache,
    otp_app: :kith,
    adapter: Nebulex.Adapters.Local
end
