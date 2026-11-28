defmodule Kith.Auth.OIDC.TransactionsTest do
  use Kith.DataCase, async: false
  alias Kith.Auth.OIDC.Transactions

  defp attrs do
    %{
      intent: :login,
      issuer: "https://issuer.test",
      redirect_uri: "https://kith.test/auth/oidc/callback",
      return_to: "/dashboard"
    }
  end

  test "a consumed transaction cannot be replayed" do
    binding = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {:ok, flow} = Transactions.start(attrs(), binding)
    assert {:ok, _} = Transactions.consume(flow.state, binding)
    assert {:error, :invalid_transaction} = Transactions.consume(flow.state, binding)
  end

  test "binding mismatch does not consume another browser's transaction" do
    {:ok, flow} = Transactions.start(attrs(), "browser-one")
    assert {:error, :invalid_transaction} = Transactions.consume(flow.state, "browser-two")
    assert {:ok, _} = Transactions.consume(flow.state, "browser-one")
  end

  test "expiry is enforced at 300 seconds without cleanup" do
    now = ~U[2026-11-09 12:00:00.000000Z]
    {:ok, flow} = Transactions.start(attrs(), "browser", now: now)

    assert {:error, :invalid_transaction} =
             Transactions.consume(flow.state, "browser", now: DateTime.add(now, 300))
  end

  test "parallel flows retain distinct protocol secrets and encrypted context" do
    {:ok, a} = Transactions.start(attrs(), "browser")
    {:ok, b} = Transactions.start(attrs(), "browser")
    refute a.nonce == b.nonce
    refute a.code_verifier == b.code_verifier

    %{rows: [[state_hash, binding_hash, payload]]} =
      Repo.query!(
        "SELECT state_hash, binding_hash, payload FROM oidc_transactions WHERE id = $1",
        [a.id]
      )

    refute state_hash == a.state
    refute binding_hash == "browser"
    refute String.contains?(payload, a.nonce)
    assert {:ok, _} = Transactions.consume(a.state, "browser")
    assert {:ok, _} = Transactions.consume(b.state, "browser")
  end

  test "unsafe destinations and incomplete link ownership fail closed" do
    for destination <- ["https://evil.test", "//evil.test", "/\\evil.test", "/%2fevil.test"] do
      assert {:error, _} = Transactions.start(%{attrs() | return_to: destination}, "browser")
    end

    assert {:error, _} = Transactions.start(%{attrs() | intent: :link}, "browser")
  end

  test "parallel independent database connections have one winner" do
    sandbox = Ecto.Adapters.SQL.Sandbox
    {:ok, flow} = sandbox.unboxed_run(Repo, fn -> Transactions.start(attrs(), "browser") end)

    try do
      results =
        1..10
        |> Task.async_stream(
          fn _ ->
            sandbox.unboxed_run(Repo, fn -> Transactions.consume(flow.state, "browser") end)
          end,
          max_concurrency: 10
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :invalid_transaction})) == 9
    after
      sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM oidc_transactions WHERE id = $1", [flow.id])
      end)
    end
  end

  test "initiating user and binary session token survive encrypted round trip" do
    user = Kith.AccountsFixtures.user_fixture()
    token = :crypto.strong_rand_bytes(32)
    attrs = Map.merge(attrs(), %{intent: :link, user_id: user.id, session_token: token})
    {:ok, flow} = Transactions.start(attrs, "browser")
    {:ok, consumed} = Transactions.consume(flow.state, "browser")
    assert consumed.user_id == user.id
    assert consumed.session_token == token
    assert consumed.intent == :link
    refute inspect(consumed) =~ Base.encode64(token)
  end

  test "purge removes expired flows while retaining active ones" do
    {:ok, old} =
      Transactions.start(attrs(), "browser", now: DateTime.add(DateTime.utc_now(), -301))

    {:ok, active} = Transactions.start(attrs(), "browser")
    assert :ok = Kith.Workers.PurgeAuthFlowsWorker.perform(%Oban.Job{})
    assert Repo.query!("SELECT id FROM oidc_transactions WHERE id = $1", [old.id]).rows == []

    assert Repo.query!("SELECT id FROM oidc_transactions WHERE id = $1", [active.id]).rows == [
             [active.id]
           ]
  end
end
