defmodule Kith.VaultCipherBoundaryTest do
  use ExUnit.Case, async: false

  alias Kith.Vault
  alias Kith.Vault.EncryptedBinary

  # Captured from Cloak 1.1.4's GCM encrypt/2 before removing the dependency.
  # Uses only the public development/test key, never production credentials.
  @fixture_key Base.decode64!("oQaI0liBwsBX4ClJyWexY+lHhC3R3RPn1t9N8VPFdho=")
  @fixtures [
    {"", "AQpBRVMuR0NNLlYxPkdXHhHWcp99TeSpEDIXQTOx1HxZpNx67C6H1rwlSj0="},
    {"legacy credential",
     "AQpBRVMuR0NNLlYxUoO/SZBctykBlgqbOBpTeZSK99VT31TMEcEzz/Pg3PJHQlvjw2xDAKWqAHezobgesw=="},
    {<<0, 255, 1>>, "AQpBRVMuR0NNLlYx99ZXaP7Uy1N6aTVeDMTIO7TTzEfbacYQG39gBS1UyT/3r+w="}
  ]

  setup do
    previous = Application.fetch_env!(:kith, Vault)
    Application.put_env(:kith, Vault, key: @fixture_key)
    on_exit(fn -> Application.put_env(:kith, Vault, previous) end)
    :ok
  end

  test "reads credentials written by the old Cloak implementation" do
    for {plaintext, encoded} <- @fixtures do
      assert {:ok, ^plaintext} = encoded |> Base.decode64!() |> EncryptedBinary.load()
    end
  end

  test "writes the legacy authenticated envelope with a fresh 16-byte IV" do
    for plaintext <- ["", "credential secret", <<0, 255, 1>>] do
      assert {:ok, first} = EncryptedBinary.dump(plaintext)
      assert {:ok, second} = EncryptedBinary.dump(plaintext)
      refute first == second

      assert <<1, 10, "AES.GCM.V1", iv::binary-size(16), mac::binary-size(16), body::binary>> =
               first

      assert :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               @fixture_key,
               iv,
               body,
               "AES256GCM",
               mac,
               false
             ) ==
               plaintext

      assert {:ok, ^plaintext} = EncryptedBinary.load(first)
    end
  end

  test "rejects altered headers, IVs, MACs, ciphertext and truncated envelopes" do
    {:ok, ciphertext} = Vault.encrypt("credential secret")

    for offset <- [0, 1, 2, 11, 12, 27, 28, 43, byte_size(ciphertext) - 1] do
      <<prefix::binary-size(offset), byte, rest::binary>> = ciphertext
      tampered = prefix <> <<Bitwise.bxor(byte, 1)>> <> rest
      assert :error = Vault.decrypt(tampered)
      assert :error = EncryptedBinary.load(tampered)
    end

    for length <- 0..43 do
      assert :error = Vault.decrypt(binary_part(ciphertext, 0, length))
    end

    assert :error = Vault.decrypt("legacy-ctr-ciphertext")
  end

  test "rejects the wrong key and never wraps the authentication sentinel in ok" do
    {:ok, ciphertext} = Vault.encrypt("credential secret")
    Application.put_env(:kith, Vault, key: :crypto.strong_rand_bytes(32))
    assert :error = Vault.decrypt(ciphertext)
    assert :error = EncryptedBinary.load(ciphertext)
  end

  test "validates key configuration without including secret values in errors" do
    assert :ok = Vault.validate_key!()

    for key <- [
          nil,
          "invalid-secret",
          :crypto.strong_rand_bytes(31),
          :crypto.strong_rand_bytes(33)
        ] do
      Application.put_env(:kith, Vault, key: key)

      assert_raise RuntimeError,
                   "CLOAK_KEY must decode to exactly 32 bytes",
                   &Vault.validate_key!/0
    end
  end

  test "ordinary Ecto binary type preserves null and rejects non-binaries" do
    assert EncryptedBinary.type() == :binary

    for function <- [&EncryptedBinary.cast/1, &EncryptedBinary.load/1, &EncryptedBinary.dump/1] do
      assert function.(nil) == {:ok, nil}
      for value <- [1, :error, %{}, []], do: assert(function.(value) == :error)
    end

    assert EncryptedBinary.cast(<<0, 255>>) == {:ok, <<0, 255>>}
  end
end
