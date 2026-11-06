defmodule Kith.Workers.ExportWorker do
  @moduledoc """
  Oban worker for generating large JSON exports asynchronously.

  When an account has 500+ contacts, the export is generated in the background
  and a download notification is sent (logged for now — email integration
  requires Swoosh mailer setup with export download templates).
  """

  use Oban.Worker, queue: :exports, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "user_id" => user_id}}) do
    Logger.info("Starting JSON export for account #{account_id}, user #{user_id}")

    export = Kith.Exports.build_json_export(account_id)
    json_data = Jason.encode_to_iodata!(export)

    # Generate a signed download token (24-hour expiry)
    token =
      Phoenix.Token.sign(
        KithWeb.Endpoint,
        "export_download",
        %{account_id: account_id, generated_at: System.system_time(:second)}
      )

    # Store the export data temporarily (in-memory ETS or file system)
    # For production, this would upload to object storage
    export_key = "export_#{account_id}_#{System.system_time(:second)}"
    cache_export(export_key, json_data, token)

    Logger.info(
      "JSON export complete for account #{account_id}. " <>
        "#{byte_size(IO.iodata_to_binary(json_data))} bytes generated. Token: #{String.slice(token, 0, 20)}..."
    )

    :ok
  end

  @doc false
  def cache_export(key, data, token) do
    # The shared OS temporary directory is not a trusted cache root. Reserve a
    # fresh, unpredictable directory atomically; never follow an existing name.
    # The application OS user is trusted (as for its upload storage tree).
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    dir = Path.join(System.tmp_dir!(), "kith_export_#{suffix}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)

    try do
      path = Path.join(dir, "export.json")
      File.write!(path, data, [:exclusive])
      File.chmod!(path, 0o600)
      meta_path = Path.join(dir, "export.meta")

      File.write!(
        meta_path,
        Jason.encode!(%{
          key: key,
          token: token,
          expires_at: System.system_time(:second) + 86_400
        }),
        [:exclusive]
      )

      File.chmod!(meta_path, 0o600)
      {:ok, dir}
    rescue
      error ->
        File.rm_rf!(dir)
        reraise error, __STACKTRACE__
    end
  end
end
