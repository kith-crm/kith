defmodule Kith.Accounts.CoseKeyTest do
  use ExUnit.Case, async: true

  alias Kith.Accounts.CoseKey

  @key %{1 => 2, 3 => -7, -1 => 1, -2 => <<1::256>>, -3 => <<2::256>>}

  test "decodes the persisted EC2, RSA and EdDSA public key shapes" do
    for key <- [
          @key,
          %{1 => 3, 3 => -257, -1 => :binary.copy(<<1>>, 256), -2 => <<1, 0, 1>>},
          %{1 => 1, 3 => -8, -1 => 6, -2 => <<3::256>>}
        ] do
      assert {:ok, ^key} = CoseKey.decode(:erlang.term_to_binary(key))
    end
  end

  test "rejects malformed, oversized, compressed and trailing ETF before use" do
    valid = :erlang.term_to_binary(@key)

    for binary <- [
          nil,
          "not ETF",
          <<131, 255>>,
          valid <> "trailing",
          :erlang.term_to_binary(@key, compressed: 9),
          :erlang.term_to_binary(:binary.copy(<<0>>, 9000))
        ] do
      assert {:error, :invalid_key} = CoseKey.decode(binary)
    end
  end

  test "rejects unexpected terms and invalid public-key shapes" do
    for term <- [
          self(),
          fn -> :ok end,
          %{},
          %{1 => 2},
          Map.put(@key, -1, 999),
          Map.put(@key, -2, <<0>>),
          Map.put(@key, 3, -257),
          Map.put(@key, 10, %{})
        ] do
      assert {:error, :invalid_key} = CoseKey.decode(:erlang.term_to_binary(term))
    end
  end

  test "does not create new atoms from stored data" do
    name = "invalid_cose_atom_#{System.unique_integer([:positive])}"
    binary = <<131, 119, byte_size(name), name::binary>>
    assert {:error, :invalid_key} = CoseKey.decode(binary)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
