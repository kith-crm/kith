defmodule KithWeb.Plugs.RequireOptionalFeature do
  @moduledoc "Rejects API access to disabled workspace features."

  import Plug.Conn

  alias Kith.Accounts.OptionalFeatures

  alias KithWeb.API.FallbackController

  def init(feature), do: feature

  def call(conn, feature) do
    if OptionalFeatures.enabled?(conn.assigns.current_scope.account, feature) do
      conn
    else
      conn
      |> FallbackController.call({:error, :feature_disabled, feature})
      |> halt()
    end
  end
end
