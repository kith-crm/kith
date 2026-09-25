defmodule Kith.ConfigHelpers do
  @moduledoc false

  def read_secret(env_var) do
    case System.get_env("#{env_var}_FILE") do
      nil -> System.get_env(env_var)
      file_path -> file_path |> String.trim() |> File.read!() |> String.trim()
    end
  end

  # `:ex_aws, :s3` endpoint options for AWS_S3_ENDPOINT. The scheme comes from
  # the URL so https endpoints get https presigned URLs.
  def s3_endpoint_config(endpoint) do
    uri = URI.parse(endpoint)
    [scheme: "#{uri.scheme || "http"}://", host: uri.host, port: uri.port]
  end

  def oban_pruner_max_age_seconds do
    "OBAN_PRUNER_MAX_AGE_DAYS"
    |> System.get_env("7")
    |> String.to_integer()
    |> Kernel.*(24 * 60 * 60)
  end
end
