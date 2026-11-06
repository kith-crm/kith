defmodule Kith.DAV.FieldRegistry do
  @moduledoc """
  Trusted built-in contact-field destinations for DAV.

  Protocols, labels and names are presentation metadata and never grant DAV
  visibility. Only audited global rows with a known system key are shared.
  """
  import Ecto.Query
  alias Kith.Contacts.ContactFieldType
  alias Kith.Repo

  @definitions [
    %{
      system_key: "email",
      name: "Email",
      protocol: "mailto:",
      icon: "mail",
      vcard_label: "EMAIL"
    },
    %{system_key: "phone", name: "Phone", protocol: "tel:", icon: "phone", vcard_label: "TEL"},
    %{
      system_key: "mobile",
      name: "Mobile",
      protocol: "tel:",
      icon: "smartphone",
      vcard_label: "TEL;TYPE=CELL"
    },
    %{
      system_key: "work_phone",
      name: "Work phone",
      protocol: "tel:",
      icon: "phone",
      vcard_label: "TEL;TYPE=WORK"
    },
    %{
      system_key: "fax",
      name: "Fax",
      protocol: "tel:",
      icon: "printer",
      vcard_label: "TEL;TYPE=FAX"
    },
    %{
      system_key: "website",
      name: "Website",
      protocol: "https://",
      icon: "globe",
      vcard_label: "URL"
    }
  ]
  @kind_by_key %{
    "email" => :emails,
    "phone" => :phones,
    "mobile" => :phones,
    "work_phone" => :phones,
    "fax" => :phones,
    "website" => :urls
  }
  @canonical_keys %{emails: "email", phones: "phone", urls: "website"}

  def definitions, do: @definitions

  def kind(%{account_id: nil, system_key: key}), do: Map.get(@kind_by_key, key)
  def kind(_), do: nil

  def canonical_type(kind) do
    with {:ok, key} <- Map.fetch(@canonical_keys, kind),
         %ContactFieldType{} = type <-
           Repo.one(
             from(t in ContactFieldType, where: is_nil(t.account_id) and t.system_key == ^key)
           ) do
      {:ok, type}
    else
      _ -> {:error, :missing_shared_field_type}
    end
  end

  def canonical_type!(kind) do
    case canonical_type(kind) do
      {:ok, type} -> type
      {:error, _} -> raise "Missing trusted DAV contact-field destination for #{inspect(kind)}"
    end
  end
end
