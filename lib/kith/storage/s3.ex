defmodule Kith.Storage.S3 do
  @moduledoc """
  S3 / S3-compatible storage backend using `ex_aws` + `ex_aws_s3`.

  Reads configuration from application env (set in runtime.exs):
  - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`
  - `AWS_S3_BUCKET`
  - `AWS_S3_ENDPOINT` (optional, for MinIO/custom S3-compatible services)

  Generates presigned GET URLs with 1-hour expiry for secure file access.
  """

  @behaviour Kith.Storage.Backend

  require Logger

  @presign_expiry 3600

  @impl true
  def upload(source_path, storage_key, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, Kith.Storage.content_type(storage_key))

    case File.read(source_path) do
      {:ok, binary} ->
        upload_binary(binary, storage_key, Keyword.put(opts, :content_type, content_type))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def upload_binary(binary, storage_key, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, Kith.Storage.content_type(storage_key))

    disposition =
      if String.starts_with?(content_type, "image/"), do: "inline", else: "attachment"

    result =
      bucket()
      |> ExAws.S3.put_object(storage_key, binary,
        content_type: content_type,
        content_disposition: disposition
      )
      |> ExAws.request()

    case result do
      {:ok, _} ->
        {:ok, storage_key}

      {:error, reason} ->
        Logger.error("S3 upload failed for #{storage_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def read(storage_key) do
    result =
      bucket()
      |> ExAws.S3.get_object(storage_key)
      |> ExAws.request()

    case result do
      {:ok, %{body: body}} ->
        {:ok, body}

      {:error, reason} ->
        Logger.error("S3 read failed for #{storage_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def delete(storage_key) do
    result =
      bucket()
      |> ExAws.S3.delete_object(storage_key)
      |> ExAws.request()

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("S3 delete failed for #{storage_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def url(storage_key) do
    presigned_url(storage_key)
  end

  @doc """
  Generates a presigned GET URL for an S3 object.
  The URL expires after 1 hour (3600 seconds).
  """
  def presigned_url(storage_key, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, @presign_expiry)

    config = ExAws.Config.new(:s3)

    case ExAws.S3.presigned_url(config, :get, bucket(), storage_key, expires_in: expires_in) do
      {:ok, url} ->
        url

      {:error, reason} ->
        Logger.error("S3 presigned URL generation failed: #{inspect(reason)}")
        "#error"
    end
  end

  @doc """
  Returns the `scheme://host[:port]` origin that presigned URLs point at, for
  the CSP `img-src` directive. Presigned URLs are path-style, so the ExAws
  config host is the exact origin the browser will request.
  """
  def csp_img_src do
    config = ExAws.Config.new(:s3)
    scheme = Map.get(config, :scheme) || "https://"
    host = Map.get(config, :host) || "s3.amazonaws.com"

    case Map.get(config, :port) do
      port when port in [nil, 80, 443] -> "#{scheme}#{host}"
      port -> "#{scheme}#{host}:#{port}"
    end
  rescue
    _ -> ""
  end

  defp bucket do
    Application.get_env(:kith, Kith.Storage, [])
    |> Keyword.fetch!(:bucket)
  end
end
