defmodule KithWeb.ContactLive.ClusterMergeS3Test do
  # Sets global S3 config.
  use KithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup %{conn: conn} do
    saved =
      for {app, key} <- [
            {:kith, Kith.Storage},
            {:ex_aws, :s3},
            {:ex_aws, :access_key_id},
            {:ex_aws, :secret_access_key},
            {:ex_aws, :region}
          ],
          do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:kith, Kith.Storage, backend: :s3, bucket: "kith-test")
    Application.put_env(:ex_aws, :access_key_id, "test")
    Application.put_env(:ex_aws, :secret_access_key, "test")
    Application.put_env(:ex_aws, :region, "us-east-1")
    Application.put_env(:ex_aws, :s3, scheme: "https://", host: "s3.example.com", port: 443)

    on_exit(fn ->
      for {app, key, v} <- saved do
        case v do
          {:ok, val} -> Application.put_env(app, key, val)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), account_id: user.account_id}
  end

  # Presigned URLs are signed per UTC hour, so a run that straddles an hour
  # boundary can flake once.
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
    assert src.() == before
  end
end
