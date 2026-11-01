defmodule Kith.SentryEventHandlerTest do
  use ExUnit.Case, async: true

  alias Kith.SentryEventHandler

  describe "scrub_params/1" do
    test "scrubs password fields" do
      params = %{"password" => "secret123", "email" => "user@example.com"}
      result = SentryEventHandler.scrub_params(params)

      assert result["password"] == "[FILTERED]"
      assert result["email"] == "user@example.com"
    end

    test "scrubs all sensitive keys" do
      params = %{
        "password" => "secret",
        "password_confirmation" => "secret",
        "token" => "abc123",
        "api_key" => "key-123",
        "secret" => "my-secret",
        "current_password" => "old",
        "new_password" => "new",
        "safe_field" => "visible"
      }

      result = SentryEventHandler.scrub_params(params)

      assert result["password"] == "[FILTERED]"
      assert result["password_confirmation"] == "[FILTERED]"
      assert result["token"] == "[FILTERED]"
      assert result["api_key"] == "[FILTERED]"
      assert result["secret"] == "[FILTERED]"
      assert result["current_password"] == "[FILTERED]"
      assert result["new_password"] == "[FILTERED]"
      assert result["safe_field"] == "visible"
    end

    test "scrubs nested maps" do
      params = %{"user" => %{"password" => "secret", "name" => "Bob"}}
      result = SentryEventHandler.scrub_params(params)

      assert result["user"]["password"] == "[FILTERED]"
      assert result["user"]["name"] == "Bob"
    end

    test "scrubs maps inside lists, keyword pairs and case-insensitive headers" do
      params = %{
        "nested" => [%{"api_key" => "list-secret"}, [token: "keyword-secret"]],
        "headers" => [
          {"Authorization", "Bearer header-secret"},
          {"Content-Type", "application/json"}
        ],
        "atom_headers" => %{refresh_token: "refresh-secret"}
      }

      result = SentryEventHandler.scrub_params(params)
      assert result["nested"] == [%{"api_key" => "[FILTERED]"}, [token: "[FILTERED]"]]

      assert result["headers"] == [
               {"Authorization", "[FILTERED]"},
               {"Content-Type", "application/json"}
             ]

      assert result["atom_headers"] == %{refresh_token: "[FILTERED]"}
    end

    test "redacts serialized URL/query credentials while preserving ordinary query values" do
      result =
        SentryEventHandler.scrub_params(%{
          url:
            "https://user:url-secret@example.com/path?token=query-secret&page=2&tag=a&tag=b#access_token=fragment-secret",
          query_string: "filter%5Bapi_key%5D=nested-secret&name=visible"
        })

      uri = URI.parse(result.url)
      assert uri.userinfo == "[FILTERED]"
      assert URI.decode_query(uri.fragment) == %{"access_token" => "[FILTERED]"}

      assert Enum.to_list(URI.query_decoder(uri.query)) ==
               [{"token", "[FILTERED]"}, {"page", "2"}, {"tag", "a"}, {"tag", "b"}]

      assert URI.decode_query(result.query_string) == %{
               "filter[api_key]" => "[FILTERED]",
               "name" => "visible"
             }
    end

    test "handles non-map values" do
      assert SentryEventHandler.scrub_params("string") == "string"
      assert SentryEventHandler.scrub_params(nil) == nil
    end
  end

  describe "before_send/1" do
    test "keeps event and request structs and scrubs all credential-bearing context" do
      Logger.metadata(user_id: 12, account_id: 34)

      event =
        Sentry.Event.create_event(
          message: "Synthetic failure",
          request: %{data: %{"rows" => [%{"password" => "request-secret"}]}},
          extra: %{credentials: [%{access_token: "extra-secret"}]}
        )

      assert %Sentry.Event{} = sanitized = SentryEventHandler.before_send(event)
      assert %Sentry.Interfaces.Request{} = sanitized.request
      assert sanitized.request.data == %{"rows" => [%{"password" => "[FILTERED]"}]}
      assert sanitized.extra.credentials == [%{access_token: "[FILTERED]"}]
      assert sanitized.user == %{id: 12, account_id: 34}
    end

    test "allows a valid event without request context" do
      event = %{Sentry.Event.create_event(message: "Synthetic failure") | request: nil}
      assert %Sentry.Event{request: nil} = SentryEventHandler.before_send(event)
    end

    test "drops events when enrichment or redaction fails" do
      Logger.metadata(user_id: 12)
      event = Sentry.Event.create_event(message: "Synthetic failure")
      assert is_nil(SentryEventHandler.before_send(%{event | user: "malformed context"}))
      assert is_nil(SentryEventHandler.before_send(%{event | extra: %{rows: [1 | :malformed]}}))
      assert is_nil(SentryEventHandler.before_send(:malformed))
    end
  end

  test "metric callback explicitly declines collection" do
    metric = %Sentry.Metric{type: :counter, name: "synthetic", value: 1, timestamp: 1.0}
    assert is_nil(SentryEventHandler.before_send_metric(metric))
  end
end
