defmodule Kith.Imports do
  @moduledoc """
  The Imports context — manages import jobs, source resolution, and import record tracking.
  """

  import Ecto.Query, warn: false
  alias Kith.Accounts.Scope
  alias Kith.Imports.{Import, ImportRecord}
  alias Kith.Repo

  @sources %{
    "monica_api" => Kith.Imports.Sources.MonicaApi,
    "vcard" => Kith.Imports.Sources.VCard
  }

  ## Import Jobs

  def create_import(account_id, user_id, attrs) do
    if has_active_import?(account_id) do
      {:error, :import_in_progress}
    else
      %Import{account_id: account_id, user_id: user_id}
      |> Import.create_changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, import} ->
          {:ok, import}

        {:error,
         %{
           errors: [
             {:account_id,
              {_, [constraint: :unique, constraint_name: "imports_one_active_per_account_idx"]}}
             | _
           ]
         }} ->
          {:error, :import_in_progress}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def get_import!(id), do: Repo.get!(Import, id)
  def get_import(id), do: Repo.get(Import, id)

  def update_import_status(%Import{} = import, status, attrs \\ %{}) do
    import
    |> Import.status_changeset(status, attrs)
    |> Repo.update()
  end

  def cancel_import(%Import{} = import) do
    update_import_status(import, "cancelled")
  end

  def get_active_import(account_id) do
    Import
    |> where([i], i.account_id == ^account_id)
    |> where([i], i.status in ["pending", "processing"])
    |> Repo.one()
  end

  defp has_active_import?(account_id) do
    Import
    |> where([i], i.account_id == ^account_id)
    |> where([i], i.status in ["pending", "processing"])
    |> Repo.exists?()
  end

  def list_imports(%Scope{} = scope) do
    Import
    |> where([i], i.account_id == ^scope.account.id)
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  def get_import(%Scope{} = scope, id) do
    Import
    |> where([i], i.id == ^id and i.account_id == ^scope.account.id)
    |> Repo.one()
  end

  def update_sync_summary(%Import{} = import, sync_summary) when is_map(sync_summary) do
    import
    |> Ecto.Changeset.change(sync_summary: sync_summary)
    |> Repo.update()
  end

  ## Source Resolution

  def resolve_source(source) when is_binary(source) do
    case Map.get(@sources, source) do
      nil -> {:error, :unknown_source}
      mod -> {:ok, mod}
    end
  end

  ## Import Records

  def find_import_record(account_id, source, source_entity_type, source_entity_id) do
    ImportRecord
    |> where([r], r.account_id == ^account_id)
    |> where([r], r.source == ^source)
    |> where([r], r.source_entity_type == ^source_entity_type)
    |> where([r], r.source_entity_id == ^source_entity_id)
    |> Repo.one()
  end

  def record_imported_entity(
        %Import{} = import,
        source_entity_type,
        source_entity_id,
        local_entity_type,
        local_entity_id
      ) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ImportRecord{}
    |> ImportRecord.changeset(%{
      account_id: import.account_id,
      import_id: import.id,
      source: import.source,
      source_entity_type: source_entity_type,
      source_entity_id: source_entity_id,
      local_entity_type: local_entity_type,
      local_entity_id: local_entity_id
    })
    |> Repo.insert(
      on_conflict: [set: [import_id: import.id, updated_at: now]],
      conflict_target:
        {:unsafe_fragment, ~s|("account_id", "source", "source_entity_type", "source_entity_id")|},
      returning: true
    )
  end

  def list_import_records(import_id) do
    ImportRecord
    |> where([r], r.import_id == ^import_id)
    |> Repo.all()
  end

  def count_import_records_by_type(import_id, entity_type) do
    ImportRecord
    |> where([r], r.import_id == ^import_id)
    |> where([r], r.source_entity_type == ^entity_type)
    |> Repo.aggregate(:count)
  end

  def wipe_api_key(%Import{} = import) do
    import
    |> Ecto.Changeset.change(api_key_encrypted: nil)
    |> Repo.update()
  end

  @doc """
  Encrypts a credential secret (e.g. an API key) for safe placement in Oban
  job args. Job args are stored as plaintext JSON in `oban_jobs` and rendered
  as-is by the Oban Web dashboard, so raw secrets must never be put there.
  """
  def encrypt_credential(plaintext) when is_binary(plaintext) do
    {:ok, ciphertext} = Kith.Vault.encrypt(plaintext)
    Base.encode64(ciphertext)
  end

  @doc "Reverses `encrypt_credential/1`."
  def decrypt_credential(ciphertext) when is_binary(ciphertext) do
    {:ok, plaintext} =
      ciphertext
      |> Base.decode64!()
      |> Kith.Vault.decrypt()

    plaintext
  end
end
