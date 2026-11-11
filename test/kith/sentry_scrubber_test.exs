defmodule Kith.SentryScrubberTest do
  use ExUnit.Case, async: true

  test "installed callback scrubs query credentials across requests, breadcrumbs and errors" do
    event = %Sentry.Event{
      event_id: "test",
      timestamp: "2026-11-09T00:00:00Z",
      request: %{
        url: "https://kith.test/auth/oidc/callback?code=CODEMARK&state=STATEMARK",
        query_string: "code=CODEMARK",
        headers: [{"cookie", "COOKIESECRET"}]
      },
      extra: %{code_verifier: "VERIFIERMARK", nonce: "NONCEMARK", payload: "PAYLOADMARK"},
      breadcrumbs: [%{message: "GET /auth/oidc/callback?code=CODEMARK&state=STATEMARK"}],
      exception: [%{value: "callback failed code=CODEMARK&state=STATEMARK"}]
    }

    assert %Sentry.Event{} = scrubbed = Kith.SentryScrubber.before_send(event)
    encoded = inspect(scrubbed)

    for marker <- ~w(CODEMARK STATEMARK COOKIESECRET VERIFIERMARK NONCEMARK PAYLOADMARK),
        do: refute(encoded =~ marker)

    assert Application.fetch_env!(:sentry, :before_send) == {Kith.SentryScrubber, :before_send}
  end
end
