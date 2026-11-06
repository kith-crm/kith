defmodule Kith.LogRedactor do
  @moduledoc false
  @behaviour LoggerJSON.Redactor

  @impl true
  def new(options \\ []), do: {__MODULE__, options}

  @impl true
  def redact(key, value, _options) do
    {_key, scrubbed} = Kith.SentryEventHandler.scrub_params({key, value})
    scrubbed
  rescue
    _ -> "[FILTERED]"
  end
end
