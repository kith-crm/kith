defmodule Kith.Auth.OIDC.Metadata do
  @moduledoc "HTTPS discovery and bounded successful metadata/key caching for the configured issuer."
  alias Kith.Cache

  defmodule HTTPAdapter do
    @moduledoc false
    @behaviour Assent.HTTPAdapter
    alias Assent.HTTPAdapter.HTTPResponse
    alias Kith.Auth.OIDC.Metadata

    @impl true
    def request(method, url, body, headers, opts) do
      if Metadata.https?(url) do
        task = Task.async(fn -> perform(method, url, body, headers, opts) end)

        case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {:error, :unavailable}
        end
      else
        {:error, :unavailable}
      end
    end

    defp perform(method, url, body, headers, opts) do
      tls = [verify: :verify_peer] ++ Keyword.take(opts, [:cacertfile])

      options = [
        method: method,
        url: url,
        headers: headers,
        body: body,
        redirect: false,
        retry: false,
        decode_body: false,
        finch: [pool_timeout: 3000, conn_opts: [transport_opts: [timeout: 3000] ++ tls]],
        receive_timeout: 5000,
        request_timeout: 5000
      ]

      case Req.request(options) do
        {:ok, response} ->
          headers = for {key, values} <- response.headers, value <- values, do: {key, value}
          {:ok, %HTTPResponse{status: response.status, headers: headers, body: response.body}}

        {:error, _} ->
          {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    end
  end

  def get(config) when is_list(config) do
    issuer = config[:issuer]

    if https?(issuer) do
      cached(config, :discovery, fn -> discover(issuer, config) end)
    else
      {:error, :invalid_metadata}
    end
  end

  def get(_), do: {:error, :invalid_metadata}

  defp discover(issuer, config) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    with {:ok, data, headers} <- fetch(url, config),
         true <- valid_metadata?(data, issuer) do
      {:ok, data, headers}
    else
      false -> {:error, :invalid_metadata}
      error -> error
    end
  end

  def key(metadata, kid, config) when is_binary(kid) or is_nil(kid) do
    with {:ok, keys} <- keys(metadata, config, false) do
      case find_key(keys, kid) do
        nil -> refresh_key(metadata, kid, config)
        key -> {:ok, key}
      end
    end
  end

  def key(_, _, _), do: {:error, :invalid_token}

  defp refresh_key(metadata, kid, config) do
    with {:ok, keys} <- keys(metadata, config, true),
         key when not is_nil(key) <- find_key(keys, kid) do
      {:ok, key}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def fetch(url, config) do
    with {:ok, %{status: 200, body: body, headers: headers}} <-
           HTTPAdapter.request(:get, url, nil, [], config),
         {:ok, data} when is_map(data) <- Jason.decode(body) do
      {:ok, data, headers}
    else
      _ -> {:error, :unavailable}
    end
  end

  def https?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        not Regex.match?(~r/\s/, value)

      _ ->
        false
    end
  end

  def https?(_), do: false

  defp keys(metadata, config, refresh) do
    cached(
      config,
      {:jwks, metadata["jwks_uri"]},
      fn ->
        case fetch(metadata["jwks_uri"], config) do
          {:ok, %{"keys" => keys}, headers} when is_list(keys) -> {:ok, keys, headers}
          _ -> {:error, :unavailable}
        end
      end,
      refresh
    )
  end

  defp find_key(keys, kid) do
    case Enum.filter(keys, fn key ->
           is_map(key) and matches_kid?(key, kid) and key["kty"] == "RSA" and
             key["alg"] in [nil, "RS256"] and key["use"] in [nil, "sig"] and
             (is_nil(key["key_ops"]) or "verify" in key["key_ops"])
         end) do
      [key] -> key
      _ -> nil
    end
  end

  defp matches_kid?(_, nil), do: true
  defp matches_kid?(key, kid), do: key["kid"] == kid

  defp valid_metadata?(data, issuer) do
    data["issuer"] == issuer and
      Enum.all?(~w(authorization_endpoint token_endpoint jwks_uri), &https?(data[&1])) and
      optional_endpoint?(data["userinfo_endpoint"]) and profile?(data)
  end

  defp optional_endpoint?(nil), do: true
  defp optional_endpoint?(url), do: https?(url)

  defp profile?(data) do
    supported?(data, "response_types_supported", "code", []) and
      supported?(data, "response_modes_supported", "query", ["query", "fragment"]) and
      supported?(data, "grant_types_supported", "authorization_code", ["authorization_code"]) and
      supported?(data, "token_endpoint_auth_methods_supported", "client_secret_basic", [
        "client_secret_basic"
      ]) and
      supported?(data, "id_token_signing_alg_values_supported", "RS256", []) and
      supported?(data, "code_challenge_methods_supported", "S256", ["S256"])
  end

  defp supported?(data, key, value, default) do
    values = Map.get(data, key, default)
    is_list(values) and value in values
  end

  defp cached(config, kind, fetch, refresh \\ false) do
    key = {__MODULE__, config[:issuer], config[:cacertfile], kind}
    now = Keyword.get(config, :clock, fn -> System.monotonic_time(:second) end).()

    case Cache.get(key) do
      {:ok, {expires, data}} when is_integer(expires) and expires > now and not refresh ->
        {:ok, data}

      _ ->
        case fetch.() do
          {:ok, data, headers} ->
            ttl = freshness(headers)
            Cache.put(key, {now + ttl, data}, ttl: max(ttl * 1000, 1))
            {:ok, data}

          error ->
            Cache.delete(key)
            error
        end
    end
  end

  defp freshness(headers) do
    value =
      headers
      |> Enum.filter(&(elem(&1, 0) == "cache-control"))
      |> Enum.map_join(",", &elem(&1, 1))

    if String.contains?(value, ["no-store", "no-cache"]) do
      0
    else
      case Regex.run(~r/max-age=(\d+)/, value) do
        [_, seconds] -> min(String.to_integer(seconds), 300)
        _ -> 300
      end
    end
  end
end
