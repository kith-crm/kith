defmodule Kith.ConfigHelpers do
  @moduledoc false

  def read_secret(env_var) do
    read_secret(env_var, System.get_env())
  end

  def read_secret(env_var, env) do
    case Map.get(env, "#{env_var}_FILE") do
      nil -> Map.get(env, env_var)
      file_path -> file_path |> String.trim() |> File.read!() |> String.trim()
    end
  end

  # `:ex_aws, :s3` endpoint options for AWS_S3_ENDPOINT. The scheme comes from
  # the URL so https endpoints get https presigned URLs.
  def s3_endpoint_config(endpoint) do
    uri = URI.parse(endpoint)
    [scheme: "#{uri.scheme || "http"}://", host: uri.host, port: uri.port]
  end
end
