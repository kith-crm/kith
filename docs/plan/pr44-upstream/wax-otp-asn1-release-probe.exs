# This runs under the production release, without Mix or ExUnit.
modules = [:AndroidKeyAttestationV1, :AndroidKeyAttestationV2, :AndroidKeyAttestationV3]
Enum.each(modules, &Code.ensure_loaded!/1)

fixtures =
  System.fetch_env!("WAX_SCHEMA_FIXTURES") |> File.read!() |> :erlang.binary_to_term([:safe])

for module <- modules, {expected, encoded} <- Map.fetch!(fixtures, module) do
  {:ok, ^expected} = module.decode(module, encoded)
  {:ok, ^encoded} = module.encode(module, expected)
end

bytes = fn value -> %CBOR.Tag{tag: :bytes, value: value} end

{<<4, x::binary-size(32), y::binary-size(32)>>, private_key} =
  :crypto.generate_key(:ecdh, :secp256r1)

cose_key = %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}
encoded_key = CBOR.encode(Map.merge(cose_key, %{-2 => bytes.(x), -3 => bytes.(y)}))
credential_id = :crypto.strong_rand_bytes(16)
rp_hash = :crypto.hash(:sha256, "wax.example")

challenge_options = [
  origin: "https://wax.example",
  rp_id: "wax.example",
  user_verification: "required"
]

client_data = fn type, challenge ->
  Jason.encode!(%{
    type: type,
    challenge: Base.url_encode64(challenge.bytes, padding: false),
    origin: "https://wax.example"
  })
end

sign = fn auth_data, client ->
  :crypto.sign(:ecdsa, :sha256, auth_data <> :crypto.hash(:sha256, client), [
    private_key,
    :secp256r1
  ])
end

registration = Wax.new_registration_challenge(challenge_options)
registration_client = client_data.("webauthn.create", registration)

registration_auth =
  rp_hash <> <<0x45, 0::32, 0::128, byte_size(credential_id)::16>> <> credential_id <> encoded_key

attestation =
  CBOR.encode(%{
    "fmt" => "packed",
    "authData" => bytes.(registration_auth),
    "attStmt" => %{"alg" => -7, "sig" => bytes.(sign.(registration_auth, registration_client))}
  })

{:ok, {registered, {:self, nil, nil}}} =
  Wax.register(attestation, registration_client, registration)

^cose_key = registered.attested_credential_data.credential_public_key

authentication =
  Wax.new_authentication_challenge(
    challenge_options ++ [allow_credentials: [{credential_id, cose_key}]]
  )

authentication_client = client_data.("webauthn.get", authentication)
authentication_auth = rp_hash <> <<0x05, 1::32>>

{:ok, %{sign_count: 1}} =
  Wax.authenticate(
    credential_id,
    authentication_auth,
    sign.(authentication_auth, authentication_client),
    authentication_client,
    authentication
  )

IO.puts(
  "PASS production release: all three legacy ASN.1 schemas, signed packed registration and signed ES256 assertion"
)
