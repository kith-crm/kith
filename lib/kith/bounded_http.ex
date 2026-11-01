defmodule Kith.BoundedHTTP do
  @moduledoc "Response boundary for account-configured remote services."

  @max_body_bytes 20 * 1024 * 1024

  def get(url, options) do
    # Compression and archive decoders are deliberately disabled even when a
    # configured server sends a content-encoding header without negotiation.
    options =
      Keyword.merge(options,
        compressed: false,
        decoders: [:json, :json_api],
        into: &receive_chunk/2
      )

    Req.get(url, options)
  end

  defp receive_chunk({:data, chunk}, {request, response}) do
    if byte_size(response.body) + byte_size(chunk) <= @max_body_bytes do
      {:cont, {request, %{response | body: response.body <> chunk}}}
    else
      {:halt, {request, %Req.TransportError{reason: :response_too_large}}}
    end
  end
end
