# Run from a pristine Wax source checkout after compilation. See the adjacent
# shell runner; all keys, credentials and schema values are synthetic.
modules = [:AndroidKeyAttestationV1, :AndroidKeyAttestationV2, :AndroidKeyAttestationV3]
Enum.each(modules, &Code.ensure_loaded!/1)

if output = System.get_env("WAX_SCHEMA_FIXTURES_OUT") do
  :rand.seed(:exsss, {17, 29, 41})

  fixtures =
    Map.new(modules, fn module ->
      samples =
        for _ <- 1..16 do
          {:ok, value} = :asn1ct.value(module, module, i: String.to_charlist("src"))
          {:ok, encoded} = module.encode(module, value)
          {value, encoded}
        end

      {module, samples}
    end)

  File.write!(output, :erlang.term_to_binary(fixtures))
end

ExUnit.start()

defmodule WaxOtpAsn1Probe do
  use ExUnit.Case, async: false

  @fixtures System.fetch_env!("WAX_SCHEMA_FIXTURES")
            |> File.read!()
            |> :erlang.binary_to_term([:safe])

  for module <- [:AndroidKeyAttestationV1, :AndroidKeyAttestationV2, :AndroidKeyAttestationV3] do
    test "#{module} retains the legacy record and BER encoding contracts" do
      module = unquote(module)
      assert module.encoding_rule() == :ber

      for {expected, encoded} <- Map.fetch!(@fixtures, module) do
        assert {:ok, ^expected} = module.decode(module, encoded)
        assert {:ok, ^encoded} = module.encode(module, expected)
      end

      assert {:error, _reason} = module.decode(module, <<0, 255>>)
    end
  end

  test "real signed packed registration and ES256 assertion retain verification boundaries" do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private_key} =
      :crypto.generate_key(:ecdh, :secp256r1)

    cose_key = %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}
    encoded_key = CBOR.encode(Map.merge(cose_key, %{-2 => bytes(x), -3 => bytes(y)}))
    credential_id = :crypto.strong_rand_bytes(16)
    rp_hash = :crypto.hash(:sha256, "wax.example")

    registration =
      Wax.new_registration_challenge(
        origin: "https://wax.example",
        rp_id: "wax.example",
        user_verification: "required"
      )

    registration_client = client_data("webauthn.create", registration)

    registration_auth =
      rp_hash <>
        <<0x45, 0::32, 0::128, byte_size(credential_id)::16>> <> credential_id <> encoded_key

    registration_signature = sign(registration_auth, registration_client, private_key)

    attestation =
      CBOR.encode(%{
        "fmt" => "packed",
        "authData" => bytes(registration_auth),
        "attStmt" => %{"alg" => -7, "sig" => bytes(registration_signature)}
      })

    assert {:ok, {registered, {:self, nil, nil}}} =
             Wax.register(attestation, registration_client, registration)

    assert registered.attested_credential_data.credential_id == credential_id
    assert registered.attested_credential_data.credential_public_key == cose_key

    authentication =
      Wax.new_authentication_challenge(
        origin: "https://wax.example",
        rp_id: "wax.example",
        user_verification: "required",
        allow_credentials: [{credential_id, cose_key}]
      )

    authentication_client = client_data("webauthn.get", authentication)
    authentication_auth = rp_hash <> <<0x05, 1::32>>
    signature = sign(authentication_auth, authentication_client, private_key)

    assert {:ok, %{sign_count: 1}} =
             Wax.authenticate(
               credential_id,
               authentication_auth,
               signature,
               authentication_client,
               authentication
             )

    prefix_size = byte_size(signature) - 1
    <<prefix::binary-size(prefix_size), last>> = signature
    tampered_signature = prefix <> <<Bitwise.bxor(last, 1)>>

    assert {:error, _reason} =
             Wax.authenticate(
               credential_id,
               authentication_auth,
               tampered_signature,
               authentication_client,
               authentication
             )

    bad_origin_client = client_data("webauthn.get", authentication, "https://attacker.example")

    assert {:error, _reason} =
             Wax.authenticate(
               credential_id,
               authentication_auth,
               sign(authentication_auth, bad_origin_client, private_key),
               bad_origin_client,
               authentication
             )

    wrong_rp_auth = :crypto.hash(:sha256, "attacker.example") <> <<0x05, 1::32>>

    assert {:error, _reason} =
             Wax.authenticate(
               credential_id,
               wrong_rp_auth,
               sign(wrong_rp_auth, authentication_client, private_key),
               authentication_client,
               authentication
             )
  end

  defp bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}

  defp sign(auth_data, client_json, key),
    do:
      :crypto.sign(:ecdsa, :sha256, auth_data <> :crypto.hash(:sha256, client_json), [
        key,
        :secp256r1
      ])

  defp client_data(type, challenge, origin \\ "https://wax.example"),
    do:
      Jason.encode!(%{
        type: type,
        challenge: Base.url_encode64(challenge.bytes, padding: false),
        origin: origin
      })
end
