defmodule Kith.Auth.ConfigTest do
  use ExUnit.Case, async: false
  alias Kith.Auth.Config

  @oidc %{
    "OIDC_ENABLED" => "true",
    "OIDC_ISSUER" => "https://id.example/realm",
    "OIDC_CLIENT_ID" => "client",
    "OIDC_CLIENT_SECRET" => "secret-canary"
  }

  test "contradictory signup settings fail closed" do
    assert_raise ArgumentError, fn ->
      Config.from_env!(%{"REGISTRATION_ENABLED" => "true", "DISABLE_SIGNUP" => "true"})
    end
  end

  test "defaults and all independent flag combinations" do
    assert %{
             oidc_enabled: false,
             password_login_enabled: true,
             registration_enabled: true,
             oidc: nil
           } = Config.from_env!(%{})

    for oidc <- [false, true], password <- [false, true], registration <- [false, true] do
      config =
        Config.from_env!(
          Map.merge(@oidc, %{
            "OIDC_ENABLED" => to_string(oidc),
            "PASSWORD_LOGIN_ENABLED" => to_string(password),
            "REGISTRATION_ENABLED" => to_string(registration)
          })
        )

      assert config.oidc_enabled == oidc
      assert config.password_login_enabled == password
      assert config.registration_enabled == registration
    end
  end

  test "legacy and explicit registration agree or fail closed" do
    for {env, expected} <- [
          {%{"DISABLE_SIGNUP" => "true"}, false},
          {%{"DISABLE_SIGNUP" => "false"}, true},
          {%{"REGISTRATION_ENABLED" => "false"}, false},
          {%{"REGISTRATION_ENABLED" => "true", "DISABLE_SIGNUP" => "false"}, true},
          {%{"REGISTRATION_ENABLED" => "false", "DISABLE_SIGNUP" => "true"}, false}
        ] do
      assert Config.from_env!(env).registration_enabled == expected
    end

    assert_raise ArgumentError, fn ->
      Config.from_env!(%{"REGISTRATION_ENABLED" => "false", "DISABLE_SIGNUP" => "false"})
    end
  end

  test "supplied booleans must be strict" do
    for key <- [
          "OIDC_ENABLED",
          "PASSWORD_LOGIN_ENABLED",
          "REGISTRATION_ENABLED",
          "DISABLE_SIGNUP"
        ],
        value <- ["", "TRUE", "1", " true "] do
      assert_raise ArgumentError, fn -> Config.from_env!(%{key => value}) end
    end
  end

  test "enabled credentials and issuer are validated without disclosing values" do
    for key <- ["OIDC_ISSUER", "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET"],
        value <- [nil, "", "   "] do
      assert_raise ArgumentError, fn -> Config.from_env!(Map.put(@oidc, key, value)) end
    end

    for issuer <- [
          "http://id.example",
          "https://user:secret-canary@id.example",
          "https://id.example?secret-canary",
          "https://id.example/#secret-canary",
          "https:///realm",
          "https://id.example:secret-canary"
        ] do
      error =
        assert_raise ArgumentError, fn ->
          Config.from_env!(Map.put(@oidc, "OIDC_ISSUER", issuer))
        end

      refute Exception.message(error) =~ "secret-canary"
    end

    assert Config.from_env!(@oidc).oidc[:issuer] == "https://id.example/realm"
    assert Config.from_env!(@oidc).oidc[:display_name] == "OpenID Connect"

    assert Config.from_env!(%{
             "OIDC_ISSUER" => "invalid",
             "OIDC_CLIENT_SECRET_FILE" => "/missing-secret-canary"
           }).oidc == nil
  end

  test "secret files take precedence and errors are redacted" do
    path = Path.join(System.tmp_dir!(), "kith-oidc-#{System.unique_integer([:positive])}")
    File.write!(path, " file-secret \n")
    on_exit(fn -> File.rm(path) end)

    assert Config.from_env!(Map.put(@oidc, "OIDC_CLIENT_SECRET_FILE", path)).oidc[:client_secret] ==
             "file-secret"

    error =
      assert_raise ArgumentError, fn ->
        Config.from_env!(Map.put(@oidc, "OIDC_CLIENT_SECRET_FILE", "/missing-secret-canary"))
      end

    refute Exception.message(error) =~ "secret-canary"
  end

  test "startup requires a configured interactive mechanism, not existing credentials" do
    config = Config.from_env!(%{"PASSWORD_LOGIN_ENABLED" => "false"})

    assert_raise ArgumentError, fn ->
      Config.validate_runtime!(config, %{oauth_providers: %{}, passkeys_enabled: false})
    end

    assert :ok =
             Config.validate_runtime!(config, %{
               oauth_providers: %{"github" => [client_id: "id", client_secret: "secret"]}
             })

    assert :ok = Config.validate_runtime!(config, %{passkeys_enabled: true})
    assert :ok = Config.validate_runtime!(Config.from_env!(@oidc), %{})
    assert :ok = Config.validate_runtime!(Config.from_env!(%{}), %{})
  end
end
