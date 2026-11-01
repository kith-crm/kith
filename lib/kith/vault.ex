defmodule Kith.Vault do
  @moduledoc """
  Credential encryption using OTP AES-256-GCM.

  Preserves the existing Cloak AES.GCM.V1 envelope and decoded `CLOAK_KEY`,
  so stored credentials and writes remain readable across application rollback.
  This format is distinct from `Kith.EncryptedBinary`.
  """

  @header <<1, 10, "AES.GCM.V1">>
  @aad "AES256GCM"

  @doc "Validates the configured 32-byte key without exposing it in errors."
  def validate_key! do
    key!()
    :ok
  end

  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, mac} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key!(), iv, plaintext, @aad, true)

    {:ok, @header <> iv <> mac <> ciphertext}
  end

  def encrypt(_), do: :error

  def decrypt(<<@header, iv::binary-size(16), mac::binary-size(16), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key!(), iv, ciphertext, @aad, mac, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> :error
    end
  end

  def decrypt(_), do: :error

  defp key! do
    case Application.get_env(:kith, __MODULE__, [])[:key] do
      key when is_binary(key) and byte_size(key) == 32 -> key
      _ -> raise "CLOAK_KEY must decode to exactly 32 bytes"
    end
  end
end

defmodule Kith.Vault.EncryptedBinary do
  @moduledoc "Credential Ecto type preserving the existing AES.GCM.V1 ciphertext format."
  use Ecto.Type

  def type, do: :binary

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  def dump(nil), do: {:ok, nil}
  def dump(value), do: Kith.Vault.encrypt(value)

  def load(nil), do: {:ok, nil}
  def load(value), do: Kith.Vault.decrypt(value)
end
