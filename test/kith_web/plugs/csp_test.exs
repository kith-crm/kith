defmodule KithWeb.Plugs.CSPTest do
  use KithWeb.ConnCase, async: false

  setup do
    keys = [
      {:kith, Kith.Storage},
      {:ex_aws, :s3},
      {:ex_aws, :access_key_id},
      {:ex_aws, :secret_access_key},
      {:ex_aws, :region}
    ]

    saved = for {app, key} <- keys, do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:kith, Kith.Storage, backend: :s3, bucket: "kith-test")
    Application.put_env(:ex_aws, :access_key_id, "test")
    Application.put_env(:ex_aws, :secret_access_key, "test")
    Application.put_env(:ex_aws, :region, "us-east-1")
    Application.put_env(:ex_aws, :s3, scheme: "https://", host: "s3.example.com", port: 443)

    on_exit(fn ->
      for {app, key, v} <- saved do
        case v do
          {:ok, val} -> Application.put_env(app, key, val)
          :error -> Application.delete_env(app, key)
        end
      end
    end)
  end

  test "img-src includes the S3 origin", %{conn: conn} do
    conn = KithWeb.Plugs.CSP.call(conn, KithWeb.Plugs.CSP.init([]))
    [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ ~r/img-src [^;]*https:\/\/s3\.example\.com/
  end
end
