defmodule KithWeb.Plugs.MetricsAuth do
  @moduledoc """
  Plug that authenticates /metrics requests via Bearer token.

  The token is read from the METRICS_TOKEN environment variable.
  Returns 401 for missing/invalid tokens. No user session required.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected_token = Application.get_env(:kith, :metrics_token)

    cond do
      is_nil(expected_token) or expected_token == "" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Metrics endpoint not configured"}))
        |> halt()

      extract_bearer_token(conn) == expected_token ->
        conn

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Invalid or missing metrics token"}))
        |> halt()
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end
end
