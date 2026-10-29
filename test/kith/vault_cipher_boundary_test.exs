defmodule Kith.VaultCipherBoundaryTest do
  use ExUnit.Case, async: true

  test "every configured reader uses authenticated AES-GCM and tampering produces no plaintext" do
    ciphers = Application.fetch_env!(:kith, Kith.Vault) |> Keyword.fetch!(:ciphers)
    assert ciphers != []
    for {_name, {cipher, _options}} <- ciphers, do: assert(cipher == Cloak.Ciphers.AES.GCM)

    assert {:ok, ciphertext} = Kith.Vault.encrypt("credential secret")
    assert {:ok, "credential secret"} = Kith.Vault.decrypt(ciphertext)
    offset = byte_size(ciphertext) - 1
    <<prefix::binary-size(offset), last>> = ciphertext
    tampered = prefix <> <<Bitwise.bxor(last, 1)>>
    # Cloak 1.x wraps the OTP AEAD authentication-failure sentinel in :ok.
    # The result is the literal :error, never attacker-modified plaintext.
    assert {:ok, :error} = Kith.Vault.decrypt(tampered)
    assert {:error, %Cloak.MissingCipher{}} = Kith.Vault.decrypt("legacy-ctr-ciphertext")
  end
end
