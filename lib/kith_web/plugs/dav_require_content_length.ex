defmodule KithWeb.Plugs.DavRequireContentLength do
  @moduledoc """
  Answers a `Transfer-Encoding: chunked` request to the CardDAV paths with
  `411 Length Required`, before anything reads the body (CDV-29).

  Bandit reads a chunked body whole and ignores `read_body`'s `:length`, so
  neither the DAV `max-resource-size` cap (R8) nor `Plug.Parsers` can bound it.
  Must run before `Plug.Parsers` in the endpoint. The response closes the
  connection so Bandit does not drain the unread chunked body either.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: path_info} = conn, _opts) do
    if dav_path?(path_info) and chunked?(conn) do
      conn
      |> put_resp_header("connection", "close")
      |> send_resp(411, "Length Required")
      |> halt()
    else
      conn
    end
  end

  defp dav_path?(["dav" | _]), do: true
  defp dav_path?([".well-known", "carddav" | _]), do: true
  defp dav_path?(_), do: false

  defp chunked?(conn) do
    conn
    |> get_req_header("transfer-encoding")
    |> Enum.any?(&String.contains?(String.downcase(&1), "chunked"))
  end
end
