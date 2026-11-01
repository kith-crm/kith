defmodule Kith.TOTPReviewReference do
  @moduledoc false
  import Bitwise

  # Independent RFC algorithm: no POT/Base32 decoder or POT generator calls.
  def hotp(raw_key, counter, digits \\ 6, digest \\ :sha) do
    mac = :crypto.mac(:hmac, digest, raw_key, <<counter::unsigned-big-integer-size(64)>>)
    offset = band(:binary.last(mac), 15)
    value = mac |> binary_part(offset, 4) |> :binary.decode_unsigned() |> band(0x7FFFFFFF)

    value
    |> rem(Integer.pow(10, digits))
    |> Integer.to_string()
    |> String.pad_leading(digits, "0")
  end

  def timestamp(seconds, microseconds \\ 0),
    do: {div(seconds, 1_000_000), rem(seconds, 1_000_000), microseconds}

  def next_code(secret) do
    raw_key = Base.decode32!(secret, padding: false)
    hotp(raw_key, div(System.system_time(:second), 30) + 1)
  end
end

defmodule Kith.TOTPDependencyReviewTest do
  use ExUnit.Case, async: true

  alias Kith.Accounts
  alias Kith.TOTPReviewReference, as: Reference

  @sha1_key "12345678901234567890"
  @hotp_vectors ~w(755224 287082 359152 969429 338314 254676 287922 162583 399871 520489)
  @totp_vectors [
    {59, "94287082", "46119246", "90693936"},
    {1_111_111_109, "07081804", "68084774", "25091201"},
    {1_111_111_111, "14050471", "67062674", "99943326"},
    {1_234_567_890, "89005924", "91819424", "93441116"},
    {2_000_000_000, "69279037", "90698825", "38618901"},
    {20_000_000_000, "65353130", "77737706", "47863826"}
  ]

  test "RFC 4226 Appendix D agrees with POT and the independent OTP-crypto reference" do
    secret = Base.encode32(@sha1_key)

    for {expected, counter} <- Enum.with_index(@hotp_vectors) do
      assert Reference.hotp(@sha1_key, counter) == expected
      assert :pot.hotp(secret, counter) == expected
    end
  end

  test "RFC 6238 Appendix B SHA1/SHA256/SHA512 vectors including times beyond 2038" do
    keys = [
      {:sha, @sha1_key, 1},
      {:sha256, "12345678901234567890123456789012", 2},
      {:sha512, "1234567890123456789012345678901234567890123456789012345678901234", 3}
    ]

    for vector <- @totp_vectors, {digest, key, result_index} <- keys do
      seconds = elem(vector, 0)
      expected = elem(vector, result_index)
      assert Reference.hotp(key, div(seconds, 30), 8, digest) == expected

      assert :pot.totp(Base.encode32(key),
               token_length: 8,
               digest_method: digest,
               timestamp: Reference.timestamp(seconds)
             ) == expected
    end
  end

  test "30-second boundaries ignore fractional seconds and advance at the boundary" do
    secret = Base.encode32(@sha1_key)

    for counter <- [0, 1, 3, 56_666_666] do
      last_second = counter * 30 + 29
      next_second = (counter + 1) * 30

      assert :pot.totp(secret, timestamp: Reference.timestamp(last_second, 999_999)) ==
               Reference.hotp(@sha1_key, counter)

      assert :pot.totp(secret, timestamp: Reference.timestamp(next_second)) ==
               Reference.hotp(@sha1_key, counter + 1)
    end
  end

  test "Kith's exact POT options accept current and two future intervals, not the previous one" do
    secret = Base.encode32(@sha1_key, padding: false)

    for {seconds, microseconds} <- [{119, 999_999}, {120, 0}, {1_700_000_010, 0}] do
      counter = div(seconds, 30)
      codes = for offset <- -2..3, do: Reference.hotp(@sha1_key, counter + offset)
      assert MapSet.size(MapSet.new(codes)) == 6

      for {code, offset} <- Enum.zip(codes, -2..3) do
        assert :pot.valid_totp(code, secret,
                 window: 1,
                 addwindow: 1,
                 timestamp: Reference.timestamp(seconds, microseconds)
               ) == offset in 0..2
      end
    end
  end

  test "actual Accounts boundary accepts independently generated next-interval code" do
    secret = Base.encode32(@sha1_key, padding: false)
    # Next interval is accepted on either side of an intervening clock rollover.
    assert Accounts.valid_totp_code?(secret, Reference.next_code(secret))
  end

  test "POT primitive is stateless and does not itself enforce one-time consumption" do
    secret = Base.encode32(@sha1_key)
    options = [timestamp: Reference.timestamp(1_700_000_010), addwindow: 1, window: 1]
    code = Reference.hotp(@sha1_key, div(1_700_000_010, 30))
    assert :pot.valid_totp(code, secret, options)
    assert :pot.valid_totp(code, secret, options)
  end

  test "six-digit format rejects wrong lengths, non-ASCII digits and every altered digit" do
    secret = Base.encode32(@sha1_key)
    seconds = 1_700_000_010
    code = Reference.hotp(@sha1_key, div(seconds, 30))
    opts = [timestamp: Reference.timestamp(seconds)]

    for invalid <- ["", "12345", "1234567", "abcdef", "１２３４５６", "12 456", <<0, 1, 2, 3, 4, 5>>] do
      refute :pot.valid_totp(invalid, secret, opts)
    end

    for index <- 0..5 do
      <<prefix::binary-size(index), digit, suffix::binary>> = code
      replacement = if digit == ?0, do: ?1, else: ?0
      refute :pot.valid_totp(<<prefix::binary, replacement, suffix::binary>>, secret, opts)
    end
  end

  test "existing 20-byte Base32 secrets round-trip through OTP-backed storage and POT" do
    secret = Accounts.generate_totp_secret()
    assert byte_size(secret) == 32
    raw = Base.decode32!(secret, padding: false)
    assert byte_size(raw) == 20
    assert :pot_base32.decode(secret) == raw
    assert :pot_base32.decode(String.downcase(secret)) == raw
    assert {:ok, encrypted} = Kith.EncryptedBinary.dump(secret)
    assert {:ok, ^secret} = Kith.EncryptedBinary.load(encrypted)
    assert :pot.hotp(secret, 1) == Reference.hotp(raw, 1)
  end

  test "POT source API raises on non-binary input; Kith rejects it at its boundary" do
    secret = Base.encode32(@sha1_key)

    for code <- [nil, 123_456, [], ["123456"], %{"nested" => "123456"}] do
      assert_raise FunctionClauseError, fn -> :pot.valid_totp(code, secret) end
      refute Accounts.valid_totp_code?(secret, code)
    end

    for invalid_secret <- [nil, "", "!", "MY", <<255>>] do
      refute Accounts.valid_totp_code?(invalid_secret, "123456")
    end
  end
end

defmodule Kith.TOTPIntegrationBoundaryReviewTest do
  use KithWeb.ConnCase, async: false

  alias Kith.Accounts
  alias Kith.TOTPReviewReference, as: Reference
  import Kith.AccountsFixtures

  setup do
    user = user_fixture()
    secret = Base.encode32("12345678901234567890", padding: false)

    assert {:ok, {user, recovery_codes}} =
             Accounts.enable_totp(user, secret, Reference.next_code(secret))

    %{user: user, secret: secret, recovery_codes: recovery_codes, ip: unique_ip()}
  end

  test "malformed JSON second factors return API auth failures instead of request exceptions", %{
    user: user,
    ip: ip
  } do
    for code <- [123_456, [], ["123456"], %{"nested" => "123456"}] do
      conn = api_attempt(user, code, ip)
      assert json_response(conn, 401)["detail"] == "Invalid TOTP code."
    end
  end

  test "malformed browser second factors cannot crash or create sessions", %{user: user, ip: ip} do
    challenge = browser_challenge(user, ip)

    for code <- [123_456, [], ["123456"], %{"nested" => "123456"}] do
      conn = browser_attempt(challenge, code, ip)
      assert redirected_to(conn) == "/users/two-factor"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid authentication code."
      refute get_session(conn, :user_token)
    end
  end

  test "browser challenge guesses are limited separately from the password login budget", %{
    user: user,
    ip: ip
  } do
    challenge = browser_challenge(user, ip)

    for index <- 1..10 do
      conn = browser_attempt(challenge, "invalid", ip, index)
      assert redirected_to(conn) == "/users/two-factor"
      refute get_session(conn, :user_token)
    end

    denied = browser_attempt(challenge, "invalid", ip, 11)
    assert denied.status == 429
    assert_retry_after(denied)
    refute get_session(denied, :user_token)
  end

  test "missing, malformed and invalid signed challenges expire without sessions", %{ip: ip} do
    for params <- [
          %{},
          %{"totp_token" => [], "totp" => %{"code" => "123456"}},
          %{"totp_token" => "invalid", "totp" => %{"code" => "123456"}},
          %{"totp_token" => "invalid"}
        ] do
      conn =
        build_conn()
        |> Plug.Test.put_peer_data(%{address: ip, port: 12_345, ssl_cert: nil})
        |> put_req_header("content-type", "application/json")
        |> post("/users/totp-verify", Jason.encode!(params))

      assert redirected_to(conn) == "/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "session has expired"
      refute get_session(conn, :user_token)
      refute get_session(conn, :totp_token)
    end
  end

  test "per-user second-factor budget follows valid password requests across genuine client IPs",
       %{user: user} do
    for _ <- 1..10 do
      conn = api_attempt(user, "invalid", unique_ip())
      assert conn.status == 401
    end

    denied = api_attempt(user, "invalid", unique_ip())
    assert denied.status == 429
    assert_retry_after(denied)
  end

  test "browser and API share the same user's second-factor budget", %{user: user, ip: ip} do
    challenge = browser_challenge(user, ip)

    for _ <- 1..5, do: assert(api_attempt(user, "invalid", unique_ip()).status == 401)

    for _ <- 1..5,
        do:
          assert(redirected_to(browser_attempt(challenge, "invalid", ip)) == "/users/two-factor")

    denied = api_attempt(user, "invalid", unique_ip())
    assert denied.status == 429
    assert_retry_after(denied)
  end

  test "valid independent OTP and recovery codes still authenticate on both boundaries", %{
    user: user,
    secret: secret,
    recovery_codes: codes,
    ip: ip
  } do
    assert %{"token" => token} =
             api_attempt(user, Reference.next_code(secret), ip) |> json_response(201)

    assert is_binary(token)

    challenge = browser_challenge(user, ip)
    signed_in = browser_attempt(challenge, Reference.next_code(secret), ip)
    assert redirected_to(signed_in) == "/dashboard"
    assert get_session(signed_in, :user_token)

    assert %{"token" => _} = api_attempt(user, Enum.at(codes, 0), ip) |> json_response(201)
    assert api_attempt(user, Enum.at(codes, 0), ip).status == 401

    recovered = browser_attempt(challenge, Enum.at(codes, 1), ip)
    assert redirected_to(recovered) == "/dashboard"
    assert get_session(recovered, :user_token)
    assert Accounts.recovery_code_count(user) == 6
  end

  defp api_attempt(user, code, ip) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> Plug.Test.put_peer_data(%{address: ip, port: 12345, ssl_cert: nil})
    |> put_req_header("content-type", "application/json")
    |> post(
      "/api/auth/token",
      Jason.encode!(%{
        "email" => user.email,
        "password" => valid_user_password(),
        "totp_code" => code
      })
    )
  end

  defp browser_challenge(user, ip) do
    conn =
      build_conn()
      |> Map.put(:remote_ip, ip)
      |> Plug.Test.put_peer_data(%{address: ip, port: 12345, ssl_cert: nil})
      |> post("/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(conn) == "/users/two-factor"
    refute get_session(conn, :user_token)
    get_session(conn, :totp_token)
  end

  defp browser_attempt(challenge, code, ip, forged_identity \\ 1) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> Plug.Test.put_peer_data(%{address: ip, port: 12345, ssl_cert: nil})
    |> put_req_header("x-forwarded-for", "203.0.113.#{forged_identity}")
    |> put_req_header("x-kith-client-ip", "203.0.113.#{forged_identity}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/users/totp-verify",
      Jason.encode!(%{"totp_token" => challenge, "totp" => %{"code" => code}})
    )
  end

  defp assert_retry_after(conn) do
    [seconds] = get_resp_header(conn, "retry-after")
    assert {value, ""} = Integer.parse(seconds)
    assert value > 0
  end

  defp unique_ip do
    number = System.unique_integer([:positive, :monotonic])
    {198, 19, rem(div(number, 256), 256), rem(number, 256)}
  end
end
