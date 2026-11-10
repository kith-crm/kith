defmodule Kith.Auth.ChallengesTest do
  use Kith.DataCase, async: true
  alias Kith.Auth.Challenges
  import Kith.AccountsFixtures

  setup do
    user = user_fixture()
    secret = Kith.Accounts.generate_totp_secret()

    user =
      user |> Ecto.Changeset.change(totp_enabled: true, totp_secret: secret) |> Repo.update!()

    # The configured window accepts the next interval as well as the current
    # one. Use it so setup crossing a 30-second boundary does not expire the
    # successful-completion input while the challenge checks run.
    %{user: user, code: :pot.totp(secret, addwindow: 1), binding: "browser-binding-long-enough"}
  end

  test "requires browser binding and consumes successful challenges once", ctx do
    {:ok, handle} = issue(ctx)
    assert {:error, :invalid} = Challenges.complete(handle, "stolen-browser", ctx.code)
    assert {:error, :invalid} = Challenges.complete(handle, ctx.binding, "bad-code")
    assert {:ok, completion} = Challenges.complete(handle, ctx.binding, ctx.code)
    assert completion.user.id == ctx.user.id
    assert completion.intent == :login
    assert completion.mfa_authenticated_at
    assert {:error, :invalid} = Challenges.complete(handle, ctx.binding, ctx.code)
  end

  test "expired challenges cannot complete", ctx do
    {:ok, handle} = issue(ctx)
    Repo.update_all("auth_challenges", set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])
    assert {:error, :expired} = Challenges.complete(handle, ctx.binding, ctx.code)
  end

  test "recovery codes cannot complete a second challenge", ctx do
    [code | _] = Kith.Accounts.generate_recovery_codes(ctx.user)
    {:ok, first} = issue(ctx)
    {:ok, second} = issue(ctx)
    assert {:ok, _} = Challenges.complete(first, ctx.binding, code)
    assert {:error, :invalid} = Challenges.complete(second, ctx.binding, code)
  end

  test "reauth requires the same still-live originating session", ctx do
    other_token = Kith.Accounts.generate_user_session_token(user_fixture())
    assert {:error, :invalid} = issue(ctx, intent: :reauth, session_token: other_token)
    token = Kith.Accounts.generate_user_session_token(ctx.user)
    {:ok, handle} = issue(ctx, intent: :reauth, session_token: token)
    Kith.Accounts.delete_user_session_token(token)
    assert {:error, :invalid} = Challenges.complete(handle, ctx.binding, ctx.code)
  end

  test "rate limits use the existing user key", ctx do
    {:ok, handle} = issue(ctx)
    for _ <- 1..10, do: Kith.RateLimiter.check_totp_user(ctx.user.id)
    assert {:error, :rate_limited} = Challenges.complete(handle, ctx.binding, ctx.code)
  end

  test "payload is encrypted, handles and binding are hash-only, and expired challenges purge",
       ctx do
    token = Kith.Accounts.generate_user_session_token(ctx.user)
    {:ok, handle} = issue(ctx, intent: :reauth, session_token: token)
    row = Repo.one!(Kith.Auth.Challenge)
    assert row.handle_hash == :crypto.hash(:sha256, handle)
    assert row.binding_hash == :crypto.hash(:sha256, ctx.binding)

    %{rows: [[encrypted]]} =
      Repo.query!("SELECT payload FROM auth_challenges WHERE id = $1", [row.id])

    refute String.contains?(encrypted, Base.encode64(token))
    refute String.contains?(encrypted, ctx.binding)
    Repo.update_all(Kith.Auth.Challenge, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])
    assert :ok = Kith.Workers.PurgeAuthFlowsWorker.perform(%Oban.Job{})
    refute Repo.get(Kith.Auth.Challenge, row.id)
  end

  defp issue(ctx, attrs \\ []) do
    Challenges.issue(
      ctx.user,
      Map.merge(
        %{
          intent: :login,
          browser_binding: ctx.binding,
          authenticated_at: DateTime.utc_now(:second),
          return_to: "/settings/security"
        },
        Map.new(attrs)
      )
    )
  end
end
