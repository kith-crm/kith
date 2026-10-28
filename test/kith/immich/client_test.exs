defmodule Kith.Immich.ClientTest do
  use ExUnit.Case, async: true

  alias Kith.Immich.Client

  setup {Req.Test, :verify_on_exit!}

  describe "list_people/2 error handling" do
    test "returns network_error for a refused connection" do
      Req.Test.stub(Client, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, :network_error} = Client.list_people("https://immich.test", "fake-key")
    end

    test "distinguishes a timeout from other transport failures" do
      Req.Test.stub(Client, &Req.Test.transport_error(&1, :timeout))
      assert {:error, :timeout} = Client.list_people("https://immich.test", "fake-key")
    end

    for {status, expected} <- [
          {401, :unauthorized},
          {404, :not_found},
          {503, {:unexpected_status, 503}}
        ] do
      test "reports HTTP #{status}",
        do: assert_status(unquote(status), unquote(Macro.escape(expected)))
    end

    defp assert_status(status, expected) do
      Req.Test.stub(Client, &Plug.Conn.send_resp(&1, status, "failure"))
      assert {:error, ^expected} = Client.list_people("https://immich.test", "fake-key")
    end
  end

  test "authenticates and returns only named people with the correct thumbnail URL" do
    Req.Test.expect(Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/people"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["account-key"]

      Req.Test.json(conn, %{
        "people" => [%{"id" => "p1", "name" => "Mona"}, %{"id" => "p2", "name" => ""}]
      })
    end)

    assert {:ok,
            [
              %{
                id: "p1",
                name: "Mona",
                thumbnail_url: "https://immich.test/api/people/p1/thumbnail"
              }
            ]} =
             Client.list_people("https://immich.test/", "account-key")
  end
end
