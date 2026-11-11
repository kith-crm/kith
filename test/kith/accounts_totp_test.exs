defmodule Kith.AccountsTotpTest do
  use Kith.DataCase

  alias Kith.Accounts
  import Kith.AccountsFixtures

  describe "TOTP setup" do
    test "generate_totp_secret/0 returns a base32 string" do
      secret = Accounts.generate_totp_secret()
      assert is_binary(secret)
      assert String.length(secret) == 32
      assert {:ok, _} = Base.decode32(secret, padding: false)
    end

    test "totp_uri/2 generates a valid otpauth URI" do
      secret = Accounts.generate_totp_secret()
      uri = Accounts.totp_uri(secret, "test@example.com")
      assert uri =~ "otpauth://totp/"
      assert uri =~ secret
      assert uri =~ "test" and uri =~ "example.com"
      assert uri =~ "issuer="
    end

    test "totp_qr_code_data_url/1 generates a PNG data URL" do
      secret = Accounts.generate_totp_secret()
      uri = Accounts.totp_uri(secret, "test@example.com")
      data_url = Accounts.totp_qr_code_data_url(uri)
      assert String.starts_with?(data_url, "data:image/png;base64,")
    end

    test "valid_totp_code?/2 validates correct codes" do
      secret = Accounts.generate_totp_secret()
      code = :pot.totp(secret)
      assert Accounts.valid_totp_code?(secret, code)
    end

    test "valid_totp_code?/2 rejects incorrect codes" do
      secret = Accounts.generate_totp_secret()
      refute Accounts.valid_totp_code?(secret, "000000")
    end
  end

  describe "enable_totp/3" do
    test "enables TOTP with valid code and returns recovery codes" do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()
      code = :pot.totp(secret)

      assert {:ok, {updated_user, recovery_codes}} =
               Accounts.enable_totp(
                 %{user | authenticated_at: DateTime.utc_now(:second)},
                 secret,
                 code
               )

      assert updated_user.totp_enabled == true
      assert updated_user.totp_secret == secret
      assert length(recovery_codes) == 8
      assert Enum.all?(recovery_codes, &(&1 =~ ~r/^[0-9a-f]{4}-[0-9a-f]{4}$/))
    end

    test "returns error with invalid code" do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()

      assert {:error, :invalid_code} =
               Accounts.enable_totp(
                 %{user | authenticated_at: DateTime.utc_now(:second)},
                 secret,
                 "000000"
               )

      # User should NOT have TOTP enabled
      reloaded = Accounts.get_user!(user.id)
      refute reloaded.totp_enabled
    end
  end

  describe "disable_totp/1" do
    test "disables TOTP and removes recovery codes" do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()
      code = :pot.totp(secret)

      {:ok, {user, _codes}} =
        Accounts.enable_totp(%{user | authenticated_at: DateTime.utc_now(:second)}, secret, code)

      assert {:ok, updated_user} = Accounts.disable_totp(user)
      refute updated_user.totp_enabled
      assert is_nil(updated_user.totp_secret)
      assert Accounts.recovery_code_count(updated_user) == 0
    end
  end

  describe "recovery codes" do
    setup do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()
      code = :pot.totp(secret)

      {:ok, {user, recovery_codes}} =
        Accounts.enable_totp(%{user | authenticated_at: DateTime.utc_now(:second)}, secret, code)

      %{user: user, recovery_codes: recovery_codes}
    end

    test "recovery_code_count/1 returns correct count", %{user: user} do
      assert Accounts.recovery_code_count(user) == 8
    end

    test "use_recovery_code/2 consumes a valid code", %{user: user, recovery_codes: codes} do
      code = List.first(codes)
      assert Accounts.use_recovery_code(user, code)
      assert Accounts.recovery_code_count(user) == 7
    end

    test "use_recovery_code/2 rejects invalid codes", %{user: user} do
      refute Accounts.use_recovery_code(user, "invalid-code")
      assert Accounts.recovery_code_count(user) == 8
    end

    test "use_recovery_code/2 is single-use", %{user: user, recovery_codes: codes} do
      code = List.first(codes)
      assert Accounts.use_recovery_code(user, code)
      refute Accounts.use_recovery_code(user, code)
    end

    test "generate_recovery_codes/1 replaces existing codes", %{user: user} do
      new_codes = Accounts.generate_recovery_codes(user)
      assert length(new_codes) == 8
      assert Accounts.recovery_code_count(user) == 8
    end
  end

  describe "encrypted TOTP secret" do
    test "totp_secret is encrypted at rest" do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()
      code = :pot.totp(secret)

      {:ok, {user, _codes}} =
        Accounts.enable_totp(%{user | authenticated_at: DateTime.utc_now(:second)}, secret, code)

      # Read raw value from DB — should NOT equal the plaintext secret
      raw =
        Kith.Repo.one!(from(u in "users", where: u.id == ^user.id, select: u.totp_secret))

      assert is_binary(raw)
      refute raw == secret
      # But loading through schema should decrypt
      reloaded = Accounts.get_user!(user.id)
      assert reloaded.totp_secret == secret
    end
  end
end
