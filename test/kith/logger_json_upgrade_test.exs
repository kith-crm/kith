defmodule Kith.LoggerJSONUpgradeTest do
  use ExUnit.Case, async: true

  @metadata [:request_id, :client_ip, :user_id, :account_id, :reason, :import_id, :worker]
  test "runtime Basic.new formatter preserves fields, Decimal and nested credential redaction" do
    {formatter, configuration} =
      LoggerJSON.Formatters.Basic.new(
        metadata: @metadata,
        redactors: [Kith.LogRedactor.new()]
      )

    event = %{
      level: :warning,
      msg: {:string, "Import failed"},
      meta: %{
        time: 1_798_761_600_123_456,
        request_id: "request-123",
        client_ip: "2001:db8::42",
        user_id: 12,
        account_id: 34,
        import_id: 56,
        worker: "Kith.Workers.MonicaMiscDataWorker",
        api_key: "top-level-secret",
        reason: %{
          "API_KEY" => "uppercase-secret",
          immich_api_key: "immich-secret",
          api_key_encrypted: "import-secret",
          hashed_password: "password-hash-secret",
          access_token_secret: "oauth-token-secret",
          amount: Decimal.new("12.34"),
          rows: [%{api_key: "nested-secret", name: "visible"}],
          headers: [{"authorization", "Bearer header-secret"}, {"X-API-Key", "header-key-secret"}],
          extra_headers: %{Authorization: "Bearer map-header-secret"}
        }
      }
    }

    raw = formatter.format(event, configuration) |> IO.iodata_to_binary()
    assert String.ends_with?(raw, "\n")
    decoded = Jason.decode!(raw)
    assert decoded["message"] == "Import failed"
    assert decoded["severity"] == "warning"
    assert {:ok, _, 0} = DateTime.from_iso8601(decoded["time"])

    assert Enum.sort(Map.keys(decoded["metadata"])) ==
             Enum.sort(Enum.map(@metadata, &to_string/1))

    assert decoded["metadata"]["request_id"] == "request-123"
    assert decoded["metadata"]["reason"]["amount"] == "12.34"

    assert decoded["metadata"]["reason"]["rows"] == [
             %{"api_key" => "[FILTERED]", "name" => "visible"}
           ]

    assert decoded["metadata"]["reason"]["headers"] == [
             ["authorization", "[FILTERED]"],
             ["X-API-Key", "[FILTERED]"]
           ]

    assert decoded["metadata"]["reason"]["extra_headers"]["Authorization"] == "[FILTERED]"
    assert decoded["metadata"]["reason"]["API_KEY"] == "[FILTERED]"
    refute raw =~ "top-level-secret"
    refute raw =~ "nested-secret"
    refute raw =~ "header-secret"
    refute raw =~ "header-key-secret"
    refute raw =~ "uppercase-secret"
    refute raw =~ "immich-secret"
    refute raw =~ "import-secret"
    refute raw =~ "password-hash-secret"
    refute raw =~ "oauth-token-secret"
  end

  test "redaction errors filter the value instead of returning the original" do
    malformed = %{rows: [{:api_key, "must-not-return-this-secret"} | :invalid_tail]}
    assert Kith.LogRedactor.redact("reason", malformed, []) == "[FILTERED]"
  end

  test "actual credential schema fields are filtered before struct encoding" do
    {formatter, configuration} =
      LoggerJSON.Formatters.Basic.new(metadata: [:reason], redactors: [Kith.LogRedactor.new()])

    event = %{
      level: :error,
      msg: {:string, "Credential operation failed"},
      meta: %{
        time: 1_798_761_600_123_456,
        reason: %{
          account: %Kith.Accounts.Account{immich_api_key: "private-immich"},
          import: %Kith.Imports.Import{api_key_encrypted: "private-import"},
          identity: %Kith.Accounts.UserIdentity{access_token_secret: "private-oauth"},
          user: %Kith.Accounts.User{hashed_password: "private-password-hash"},
          recovery: %Kith.Accounts.UserRecoveryCode{hashed_code: "private-recovery"},
          invitation: %Kith.Accounts.AccountInvitation{token_hash: "private-invitation"}
        }
      }
    }

    raw = formatter.format(event, configuration) |> IO.iodata_to_binary()
    refute raw =~ "private-"
    reason = Jason.decode!(raw)["metadata"]["reason"]
    assert reason["account"]["immich_api_key"] == "[FILTERED]"
    assert reason["identity"]["access_token_secret"] == "[FILTERED]"
    assert reason["user"]["hashed_password"] == "[FILTERED]"
  end
end
