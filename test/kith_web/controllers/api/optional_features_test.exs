defmodule KithWeb.API.OptionalFeaturesTest do
  use KithWeb.ConnCase

  import Kith.AccountsFixtures

  alias Kith.Accounts

  test "a fresh account advertises Journal as off and denies direct access", %{conn: conn} do
    user = user_fixture()
    {token, _} = Accounts.generate_api_token(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    assert %{"data" => %{"optional_features" => %{"journal" => false}}} =
             conn |> get(~p"/api/account") |> json_response(200)

    assert %{"code" => "feature_disabled", "feature" => "journal"} =
             conn |> get(~p"/api/journal") |> json_response(403)
  end

  for {feature, method, path} <- [
        {"calls", :get, "/api/calls/123"},
        {"life_events", :get, "/api/life_event_types"},
        {"activities", :get, "/api/activity_type_categories"},
        {"tasks", :post, "/api/tasks/123/complete"},
        {"gifts", :delete, "/api/gifts/123"},
        {"conversations", :post, "/api/conversations/123/messages"}
      ] do
    @feature feature
    @method method
    @path path

    test "#{method} #{path} checks #{feature} independently of other switches", %{conn: conn} do
      user = user_fixture()
      enable_optional_features(user, Accounts.OptionalFeatures.keys())

      {:ok, _} =
        Accounts.set_optional_feature(
          Kith.AccountsFixtures.user_scope_fixture(user),
          @feature,
          false
        )

      {token, _} = Accounts.generate_api_token(user)

      result =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> dispatch(@endpoint, @method, @path)

      assert get_resp_header(result, "content-type") |> hd() =~ "application/problem+json"

      assert %{"status" => 403, "code" => "feature_disabled", "feature" => @feature} =
               json_response(result, 403)
    end
  end

  test "contact includes and statistics honor independent settings", %{conn: conn} do
    user = user_fixture()
    contact = Kith.ContactsFixtures.contact_fixture(user.account_id)
    {token, _} = Accounts.generate_api_token(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    for feature <- ~w(calls activities life_events) do
      result = get(conn, ~p"/api/contacts/#{contact.id}?include=#{feature}")
      assert %{"code" => "feature_disabled", "feature" => ^feature} = json_response(result, 403)
    end

    {:ok, _} =
      Accounts.set_optional_feature(Kith.AccountsFixtures.user_scope_fixture(user), "calls", true)

    assert %{"data" => %{"calls" => []}} =
             conn |> get(~p"/api/contacts/#{contact.id}?include=calls") |> json_response(200)

    assert %{"data" => %{"total_calls" => 0} = stats} =
             conn |> get(~p"/api/statistics") |> json_response(200)

    refute Map.has_key?(stats, "total_activities")
  end
end
