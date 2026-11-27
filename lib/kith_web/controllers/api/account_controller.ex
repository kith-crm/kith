defmodule KithWeb.API.AccountController do
  use KithWeb, :controller

  alias Kith.{Accounts, Policy}
  alias KithWeb.API.Includes

  action_fallback KithWeb.API.FallbackController

  def show(conn, params) do
    scope = conn.assigns.current_scope
    account = scope.account

    case Includes.parse_includes(params, :account) do
      {:ok, includes} ->
        account =
          if includes != [],
            do: Kith.Repo.preload(account, Includes.to_preloads(includes)),
            else: account

        data = account_json(account, includes)
        json(conn, %{data: data})

      {:error, detail} ->
        {:error, :bad_request, detail}
    end
  end

  def update(conn, %{"account" => attrs}) do
    scope = conn.assigns.current_scope
    user = scope.user
    account = scope.account

    with true <- Policy.can?(user, :update, :account),
         safe_attrs = Map.take(attrs, ["name", "timezone", "send_hour"]),
         {:ok, validated_attrs} <- validate_send_hour(safe_attrs) do
      do_update(conn, account, validated_attrs)
    else
      false -> {:error, :forbidden}
      {:error, :bad_request, msg} -> {:error, :bad_request, msg}
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request, "Missing 'account' key in request body."}
  end

  defp validate_send_hour(%{"send_hour" => sh} = attrs)
       when is_integer(sh) and sh >= 0 and sh <= 23 do
    {:ok, attrs}
  end

  defp validate_send_hour(%{"send_hour" => sh} = _attrs) when is_integer(sh) do
    {:error, :bad_request, "send_hour must be between 0 and 23."}
  end

  defp validate_send_hour(%{"send_hour" => sh} = attrs) when is_binary(sh) do
    case Integer.parse(sh) do
      {n, ""} when n >= 0 and n <= 23 -> {:ok, Map.put(attrs, "send_hour", n)}
      _ -> {:error, :bad_request, "send_hour must be between 0 and 23."}
    end
  end

  defp validate_send_hour(attrs), do: {:ok, attrs}

  defp do_update(conn, account, attrs) do
    case Accounts.update_account(account, attrs) do
      {:ok, updated} -> json(conn, %{data: account_json(updated, [])})
      {:error, cs} -> {:error, cs}
    end
  end

  defp account_json(account, includes) do
    base = %{
      id: account.id,
      name: account.name,
      optional_features: Accounts.OptionalFeatures.effective(account),
      timezone: account.timezone,
      send_hour: account.send_hour,
      inserted_at: account.inserted_at,
      updated_at: account.updated_at
    }

    Enum.reduce(includes, base, fn
      :users, acc ->
        users =
          if Ecto.assoc_loaded?(account.users),
            do: Enum.map(account.users, &user_summary/1),
            else: nil

        Map.put(acc, :users, users)

      _, acc ->
        acc
    end)
  end

  defp user_summary(user) do
    %{id: user.id, email: user.email, role: user.role}
  end
end
