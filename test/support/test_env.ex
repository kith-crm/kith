defmodule Kith.TestEnv do
  @moduledoc """
  Test helpers for global application env.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Sets `Application` env `app`/`key` to `value` and restores the previous value
  (or deletes the key) when the test exits. Call it from `setup`.
  """
  def put_env_restoring(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)

    :ok
  end

  @doc """
  Points the S3 storage backend at a fake `s3.example.com` with dummy
  credentials for the duration of the test.
  """
  def configure_s3 do
    put_env_restoring(:kith, Kith.Storage, backend: :s3, bucket: "kith-test")
    put_env_restoring(:ex_aws, :access_key_id, "test")
    put_env_restoring(:ex_aws, :secret_access_key, "test")
    put_env_restoring(:ex_aws, :region, "us-east-1")
    put_env_restoring(:ex_aws, :s3, scheme: "https://", host: "s3.example.com", port: 443)
  end
end
