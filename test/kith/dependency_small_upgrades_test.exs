defmodule Kith.DependencySmallUpgradesTest do
  use ExUnit.Case, async: true

  alias Kith.Accounts.CoseKey

  @origin "https://kith.example.invalid"
  @rp_id "kith.example.invalid"

  test "malformed indefinite CBOR becomes an error through Wax registration and COSE decoding" do
    challenge = Wax.new_registration_challenge(origin: @origin, rp_id: @rp_id)
    client_data = client_data("webauthn.create", challenge)

    for malformed <- [<<0x1F>>, <<0x3F>>, <<0xDF>>, <<0xFF>>, <<0x5F, 0x01, 0xFF>>] do
      assert {:error, :cbor_case_clause_error} = CBOR.decode(malformed)
      assert {:error, %Wax.InvalidCBORError{}} = Wax.Utils.CBOR.decode(malformed)
      assert {:error, %Wax.InvalidCBORError{}} = Wax.register(malformed, client_data, challenge)

      attested = <<0::128, 1::16, 0x01>> <> malformed
      assert {:error, %Wax.InvalidCBORError{}} = Wax.AttestedCredentialData.decode(attested)
      authenticator = :crypto.hash(:sha256, @rp_id) <> <<0x41, 0::32>> <> attested
      assert {:error, %Wax.InvalidCBORError{}} = Wax.AuthenticatorData.decode(authenticator)
    end

    for malformed <- [<<>>, <<0xA1, 0x01>>, <<0x58, 0x20, 0x01>>] do
      assert {:error, _} = CBOR.decode(malformed)
      assert {:error, %Wax.InvalidCBORError{}} = Wax.register(malformed, client_data, challenge)
    end
  end

  test "CBOR COSE key survives real Wax registration and a signed assertion" do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private_key} =
      :crypto.generate_key(:ecdh, :secp256r1)

    credential_id = :crypto.strong_rand_bytes(16)
    cose = %{1 => 2, 3 => -7, -1 => 1, -2 => bytes(x), -3 => bytes(y)}

    attested =
      <<0::128, byte_size(credential_id)::16, credential_id::binary>> <> CBOR.encode(cose)

    registration_data = :crypto.hash(:sha256, @rp_id) <> <<0x41, 0::32>> <> attested
    challenge = Wax.new_registration_challenge(origin: @origin, rp_id: @rp_id)

    object =
      CBOR.encode(%{"fmt" => "none", "authData" => bytes(registration_data), "attStmt" => %{}})

    assert {:ok, {registered, {:none, nil, nil}}} =
             Wax.register(object, client_data("webauthn.create", challenge), challenge)

    key = registered.attested_credential_data.credential_public_key
    assert {:ok, ^key} = CoseKey.decode(:erlang.term_to_binary(key))
    assert {:error, :invalid_key} = CoseKey.decode(:erlang.term_to_binary(%{key | -2 => <<1>>}))

    authentication =
      Wax.new_authentication_challenge(
        origin: @origin,
        rp_id: @rp_id,
        allow_credentials: [{credential_id, key}]
      )

    assertion_data = :crypto.hash(:sha256, @rp_id) <> <<0x01, 1::32>>
    client = client_data("webauthn.get", authentication)
    signed = assertion_data <> :crypto.hash(:sha256, client)
    signature = :crypto.sign(:ecdsa, :sha256, signed, [private_key, :secp256r1])

    assert {:ok, %{sign_count: 1}} =
             Wax.authenticate(credential_id, assertion_data, signature, client, authentication)

    altered = :crypto.hash(:sha256, @rp_id) <> <<0x01, 2::32>>

    assert {:error, %Wax.InvalidSignatureError{}} =
             Wax.authenticate(credential_id, altered, signature, client, authentication)
  end

  test "international SMTP domains retain IDNA roundtrips through Swoosh rendering" do
    for {unicode, ascii} <- [
          {"münchen.de", "xn--mnchen-3ya.de"},
          {"bücher.example", "xn--bcher-kva.example"},
          {"例え.テスト", "xn--r8jz45g.xn--zckzah"}
        ] do
      assert to_string(:idna.utf8_to_ascii(unicode)) == ascii
      assert :idna.decode(String.to_charlist(ascii)) == String.to_charlist(unicode)

      assert Swoosh.Email.Render.render_recipient({"Recipient", "contact@#{unicode}"}) ==
               ~s("Recipient" <contact@#{ascii}>)
    end

    assert :idna.encode(~c"Köln.example", [:uts46]) == ~c"xn--kln-sna.example"
  end

  test "Tz preserves finite-boundary offsets and both DST discontinuities" do
    for {instant, date, hour, offset} <- [
          {~U[2026-03-08 06:59:59Z], ~D[2026-03-08], 1, -18_000},
          {~U[2026-03-08 07:00:00Z], ~D[2026-03-08], 3, -14_400},
          {~U[2026-11-01 05:00:00Z], ~D[2026-11-01], 1, -14_400},
          {~U[2026-11-01 06:00:00Z], ~D[2026-11-01], 1, -18_000}
        ] do
      assert Kith.TimeHelper.local_date_hour(instant, "America/New_York") == {date, hour}
      local = DateTime.shift_zone!(instant, "America/New_York", Tz.TimeZoneDatabase)
      assert local.utc_offset + local.std_offset == offset
    end

    # Pacific/Apia's finite UTC offset boundary skipped 30 December 2011.
    assert Kith.TimeHelper.local_date_hour(~U[2011-12-30 09:59:59Z], "Pacific/Apia") ==
             {~D[2011-12-29], 23}

    assert Kith.TimeHelper.local_date_hour(~U[2011-12-30 10:00:00Z], "Pacific/Apia") ==
             {~D[2011-12-31], 0}

    # IANA 2026d's Palestine rules, used by Kith accounts in Asia/Hebron.
    for {instant, hour, offset} <- [
          {~U[2026-03-27 23:59:59Z], 1, 7_200},
          {~U[2026-03-28 00:00:00Z], 3, 10_800},
          {~U[2026-10-23 22:59:59Z], 1, 10_800},
          {~U[2026-10-23 23:00:00Z], 1, 7_200}
        ] do
      local = DateTime.shift_zone!(instant, "Asia/Hebron", Tz.TimeZoneDatabase)
      assert local.hour == hour
      assert local.utc_offset + local.std_offset == offset
    end
  end

  defp bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}

  defp client_data(type, challenge) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => Base.url_encode64(challenge.bytes, padding: false),
      "origin" => @origin
    })
  end
end

defmodule Kith.DependencySmallUpgradeReminderTest do
  use Kith.DataCase, async: true
  use Oban.Testing, repo: Kith.Repo

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Reminders.{Dispatcher, ReminderInstance}
  alias Kith.Workers.ReminderEmailWorker

  test "spring DST gap catches up at the next local hour exactly once" do
    reminder = reminder_at(~D[2026-03-08], 2)
    assert :ok = Dispatcher.run(~U[2026-03-08 06:59:59Z])
    assert instances(reminder.id) == []
    assert :ok = Dispatcher.run(~U[2026-03-08 07:00:00Z])
    assert [instance] = instances(reminder.id)

    assert_enqueued(
      worker: ReminderEmailWorker,
      args: %{instance_id: instance.id, snooze_count: 0}
    )

    assert :ok = Dispatcher.run(~U[2026-03-08 08:00:00Z])
    assert [_] = instances(reminder.id)
  end

  test "repeated fall DST hour cannot enqueue a duplicate reminder" do
    reminder = reminder_at(~D[2026-11-01], 1)
    assert :ok = Dispatcher.run(~U[2026-11-01 05:00:00Z])
    assert [instance] = instances(reminder.id)
    assert :ok = Dispatcher.run(~U[2026-11-01 06:00:00Z])
    assert [%{id: id}] = instances(reminder.id)
    assert id == instance.id
    assert length(all_enqueued(worker: ReminderEmailWorker)) == 1
  end

  defp reminder_at(date, hour) do
    user = user_fixture()
    contact = contact_fixture(user.account_id)

    Repo.get!(Kith.Accounts.Account, user.account_id)
    |> Ecto.Changeset.change(timezone: "America/New_York", send_hour: hour)
    |> Repo.update!()

    {:ok, reminder} =
      Kith.Reminders.create_reminder(user.account_id, user.id, %{
        contact_id: contact.id,
        title: "DST boundary",
        type: "one_time",
        anchor_date: date
      })

    reminder
  end

  defp instances(id),
    do: Repo.all(from(instance in ReminderInstance, where: instance.reminder_id == ^id))
end
