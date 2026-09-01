defmodule KithWeb.Plugs.CSP do
  @moduledoc """
  Plug that sets a Content-Security-Policy header with a per-request nonce
  and a dynamic `img-src` covering Immich thumbnails (when IMMICH_BASE_URL is
  configured) and the storage backend origin (S3/S3-compatible presigned URLs).

  The nonce is assigned to `conn.assigns.csp_nonce` for use on inline
  `<script>` and `<style>` tags in templates.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/dev/" <> _} = conn, _opts) do
    assign(conn, :csp_nonce, "dev")
  end

  def call(conn, _opts) do
    nonce = Base.encode64(:crypto.strong_rand_bytes(16))
    img_src = build_img_src()

    csp =
      "default-src 'self'; " <>
        "script-src 'self' 'nonce-#{nonce}'; " <>
        "style-src 'self' 'unsafe-inline'; " <>
        "img-src 'self' data: blob: #{img_src}; " <>
        "font-src 'self' data:; " <>
        "connect-src 'self' wss:; " <>
        "frame-src 'self'; " <>
        "frame-ancestors 'self'"

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", String.trim(csp))
  end

  defp build_img_src do
    [immich_img_src(), Kith.Storage.csp_img_src()]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp immich_img_src do
    case System.get_env("IMMICH_BASE_URL") do
      nil -> ""
      "" -> ""
      url -> url
    end
  end
end
