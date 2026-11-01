defmodule KithWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use KithWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint KithWeb.Endpoint

      use KithWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import KithWeb.ConnCase
      import KithWeb.APIHelpers
    end
  end

  setup tags do
    Kith.DataCase.setup_sandbox(tags)
    # Rate limits remain enabled in tests. Give each test a distinct actual
    # transport peer, keeping HTTP and LiveView connect_info identities aligned.
    number = System.unique_integer([:positive, :monotonic])
    peer = {198, 18, rem(div(number, 256), 256), rem(number, 256)}

    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:remote_ip, peer)
      |> Plug.Test.put_peer_data(%{address: peer, port: 12_345, ssl_cert: nil})

    {:ok, conn: conn}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = Kith.AccountsFixtures.user_fixture()
    scope = Kith.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Kith.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    Kith.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
