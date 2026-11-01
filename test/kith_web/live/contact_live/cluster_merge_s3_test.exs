defmodule KithWeb.ContactLive.ClusterMergeS3Test do
  # Sets global S3 config.
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    Kith.TestEnv.configure_s3()

    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), account_id: user.account_id}
  end

  # Presigned URLs are signed per UTC hour, so two renders can straddle an hour
  # boundary. Compare everything but the signature, and allow the signing hour
  # to roll over by exactly one hour.
  defp assert_same_url_modulo_hour_rollover(before, later) do
    parse = fn url ->
      uri = url |> String.replace("&amp;", "&") |> URI.parse()
      query = URI.decode_query(uri.query)
      {uri.path, Map.drop(query, ["X-Amz-Date", "X-Amz-Signature"]), query["X-Amz-Date"]}
    end

    {path_a, query_a, date_a} = parse.(before)
    {path_b, query_b, date_b} = parse.(later)

    assert path_a == path_b
    assert query_a == query_b
    assert query_a["X-Amz-Expires"] == "7200"

    hours = DateTime.diff(parse_amz_date(date_b), parse_amz_date(date_a), :hour)
    assert hours in [0, 1]
    if hours == 0, do: assert(before == later)
  end

  defp parse_amz_date(<<y::binary-4, m::binary-2, d::binary-2, "T", h::binary-2, "0000Z">>) do
    {:ok, dt, _} = DateTime.from_iso8601("#{y}-#{m}-#{d}T#{h}:00:00Z")
    dt
  end

  test "an avatar's URL is unchanged after toggling a member off and on", ctx do
    e =
      ContactsFixtures.contact_fixture(ctx.account_id, %{
        first_name: "Mona",
        last_name: "Vale",
        avatar: "avatars/a.png"
      })

    f =
      ContactsFixtures.contact_fixture(ctx.account_id, %{
        first_name: "Mona",
        last_name: "Vale",
        avatar: "avatars/b.png"
      })

    {low, high} = {min(e.id, f.id), max(e.id, f.id)}

    Kith.Repo.insert!(%Kith.Contacts.DuplicateCandidate{
      account_id: ctx.account_id,
      contact_id: low,
      duplicate_contact_id: high,
      score: 1.0,
      reasons: ["name_match"],
      status: "pending",
      detected_at: DateTime.utc_now(:second)
    })

    {:ok, live, _} = live(ctx.conn, "/contacts/duplicates/cluster/#{low}")

    src = fn ->
      live
      |> element("#merge-avatar-choice-0 img")
      |> render()
      |> then(&Regex.run(~r/src="([^"]+)"/, &1))
      |> List.last()
    end

    before = src.()
    live |> element("input[phx-click='toggle-member'][phx-value-id='#{f.id}']") |> render_click()
    live |> element("input[phx-click='toggle-member'][phx-value-id='#{f.id}']") |> render_click()
    assert_same_url_modulo_hour_rollover(before, src.())
  end
end
