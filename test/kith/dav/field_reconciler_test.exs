defmodule Kith.DAV.FieldReconcilerTest do
  use Kith.DataCase, async: true
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Contacts
  alias Kith.Contacts.{ContactField, ContactFieldType}
  alias Kith.DAV.{Document, FieldReconciler, FieldRegistry, Store, VCardAdapter}

  setup do
    contact = contact_fixture(user_fixture().account_id)
    Store.ensure_rows(contact.account_id)
    %{contact: Repo.preload(contact, Contacts.dav_preloads(), force: true)}
  end

  test "conflicting source indexes roll back native mutations and document state", %{
    contact: contact
  } do
    original =
      insert_field(contact, FieldRegistry.canonical_type!(:emails).id, "old@example.org", "home")

    before = Repo.reload!(contact.dav)

    for version <- ["3.0", "4.0"] do
      incoming =
        card([
          "EMAIL;PID=1.1:new@example.org",
          "CLIENTPIDMAP:1;https://example.org/one",
          "CLIENTPIDMAP:1;https://example.org/two"
        ])
        |> String.replace("VERSION:4.0", "VERSION:" <> version)

      {_attrs, nested} = VCardAdapter.vcard_to_attrs(incoming)

      assert {:error, :ambiguous_property_identity} =
               Store.transaction(contact.account_id, fn ->
                 original
                 |> Ecto.Changeset.change(value: "intermediate@example.org")
                 |> Repo.update!()

                 FieldReconciler.replace(contact, nested)
               end)

      assert Repo.get!(ContactField, original.id).value == "old@example.org"
      assert Repo.reload!(contact.dav) == before
    end
  end

  test "PID source identity updates a native row across CLIENTPIDMAP renumbering", %{
    contact: contact
  } do
    type =
      Repo.one!(
        from(t in ContactFieldType, where: is_nil(t.account_id) and t.system_key == "mobile")
      )

    original = insert_field(contact, type.id, "+12025550123", "Private native subtype label")

    old =
      card([
        "TEL;PID=5.1:+12025550123",
        "CLIENTPIDMAP:1;urn:uuid:11111111-1111-4111-8111-111111111111"
      ])

    contact = store_document(contact, old)

    incoming =
      card([
        "TEL;PID=5.7:+12025550124",
        "CLIENTPIDMAP:7;urn:uuid:11111111-1111-4111-8111-111111111111"
      ])

    {_attrs, nested} = VCardAdapter.vcard_to_attrs(incoming)

    assert {:ok, :ok} =
             Store.transaction(contact.account_id, fn ->
               FieldReconciler.replace(contact, nested)
             end)

    retained = Repo.get!(ContactField, original.id)
    assert retained.value == "+12025550124"
    assert retained.contact_field_type_id == type.id
    assert retained.label == "Private native subtype label"
  end

  test "PID sources use canonical UUID URN identity instead of URI spelling", %{contact: contact} do
    type = FieldRegistry.canonical_type!(:emails)
    original = insert_field(contact, type.id, "old@example.org", "home")

    contact =
      store_document(
        contact,
        card([
          "EMAIL;PID=5.1:old@example.org",
          "CLIENTPIDMAP:1;URN:UUID:A1111111-1111-4111-8111-111111111111"
        ])
      )

    {_attrs, nested} =
      VCardAdapter.vcard_to_attrs(
        card([
          "EMAIL;PID=5.2:new@example.org",
          "CLIENTPIDMAP:2;urn:uuid:a1111111-1111-4111-8111-111111111111"
        ])
      )

    assert {:ok, :ok} =
             Store.transaction(contact.account_id, fn ->
               FieldReconciler.replace(contact, nested)
             end)

    assert Repo.get!(ContactField, original.id).value == "new@example.org"
  end

  test "matching a PID number from a different source cannot capture a native row", %{
    contact: contact
  } do
    type = FieldRegistry.canonical_type!(:emails)
    original = insert_field(contact, type.id, "old@example.org", "home")

    contact =
      store_document(
        contact,
        card([
          "EMAIL;PID=5.1:old@example.org",
          "CLIENTPIDMAP:1;urn:uuid:11111111-1111-4111-8111-111111111111"
        ])
      )

    incoming =
      card([
        "EMAIL;PID=5.1:new@example.org",
        "CLIENTPIDMAP:1;urn:uuid:22222222-2222-4222-8222-222222222222"
      ])

    {_attrs, nested} = VCardAdapter.vcard_to_attrs(incoming)

    assert {:ok, :ok} =
             Store.transaction(contact.account_id, fn ->
               FieldReconciler.replace(contact, nested)
             end)

    refute Repo.get(ContactField, original.id)
    assert [new] = Repo.all(from(f in ContactField, where: f.contact_id == ^contact.id))
    assert new.value == "new@example.org"
    assert new.id != original.id
  end

  test "unchanged duplicate multiset retains native IDs and private impostors", %{
    contact: contact
  } do
    type = FieldRegistry.canonical_type!(:emails)
    one = insert_field(contact, type.id, "same@example.org", "home")
    two = insert_field(contact, type.id, "same@example.org", "work")

    private_type =
      Repo.insert!(%ContactFieldType{
        account_id: contact.account_id,
        name: "Private email",
        protocol: "mailto",
        vcard_label: "EMAIL"
      })

    private = insert_field(contact, private_type.id, "same@example.org", "private")
    incoming = card(["EMAIL:same@example.org", "EMAIL:same@example.org"])
    {_attrs, nested} = VCardAdapter.vcard_to_attrs(incoming)

    assert {:ok, :ok} =
             Store.transaction(contact.account_id, fn ->
               FieldReconciler.replace(contact, nested)
             end)

    assert Enum.sort(
             Repo.all(from(f in ContactField, where: f.contact_id == ^contact.id, select: f.id))
           ) == Enum.sort([one.id, two.id, private.id])
  end

  test "invalid native lengths roll back replacements and prior deletions", %{contact: contact} do
    type = FieldRegistry.canonical_type!(:emails)
    original = insert_field(contact, type.id, "old@example.org", "home")
    incoming = card(["EMAIL:" <> String.duplicate("x", 256)])
    {_attrs, nested} = VCardAdapter.vcard_to_attrs(incoming)

    assert {:error, %Ecto.Changeset{}} =
             Store.transaction(contact.account_id, fn ->
               FieldReconciler.replace(contact, nested)
             end)

    assert Repo.get!(ContactField, original.id).value == "old@example.org"
  end

  test "bulk native fields preserve input order Unicode and nullable labels", %{contact: contact} do
    incoming =
      card([
        "EMAIL;TYPE=home:é@example.org",
        "EMAIL:no-label@example.org",
        "EMAIL;TYPE=work:work@example.org"
      ])

    {_attrs, nested} = VCardAdapter.vcard_to_attrs(incoming)

    assert {:ok, :ok} =
             Store.transaction(contact.account_id, fn ->
               FieldReconciler.replace(contact, nested)
             end)

    assert Repo.all(
             from f in ContactField,
               where: f.contact_id == ^contact.id,
               order_by: f.id,
               select: {f.value, f.label}
           ) == [
             {"é@example.org", "Home"},
             {"no-label@example.org", nil},
             {"work@example.org", "Work"}
           ]
  end

  test "large replacements batch native inserts and retain IDs on unchanged multiset input", %{
    contact: contact
  } do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:kith, :repo, :query],
        fn _event, _measurements, metadata, owner ->
          if self() == owner and
               String.starts_with?(metadata.query, "INSERT INTO \"contact_fields\"") do
            send(owner, :review_native_field_insert)
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    incoming = card(Enum.map(1..2_501, &"EMAIL:bulk#{&1}@example.org"))
    {_attrs, nested} = VCardAdapter.vcard_to_attrs(incoming)

    assert {:ok, :ok} =
             Store.transaction(contact.account_id, fn ->
               FieldReconciler.replace(contact, nested)
             end)

    ids =
      Repo.all(from f in ContactField, where: f.contact_id == ^contact.id, select: f.id)
      |> Enum.sort()

    assert length(ids) == 2_501
    assert count_insert_messages(0) in 1..4

    assert {:ok, :ok} =
             Store.transaction(contact.account_id, fn ->
               FieldReconciler.replace(contact, nested)
             end)

    assert Repo.all(from f in ContactField, where: f.contact_id == ^contact.id, select: f.id)
           |> Enum.sort() == ids

    assert count_insert_messages(0) == 0

    {_attrs, empty} = VCardAdapter.vcard_to_attrs(card([]))

    assert {:ok, :ok} =
             Store.transaction(contact.account_id, fn ->
               FieldReconciler.replace(contact, empty)
             end)

    assert Repo.all(from f in ContactField, where: f.contact_id == ^contact.id) == []
  end

  defp count_insert_messages(count) do
    receive do
      :review_native_field_insert -> count_insert_messages(count + 1)
    after
      0 -> count
    end
  end

  defp store_document(contact, raw) do
    contact = Repo.preload(contact, Contacts.dav_preloads(), force: true)
    document = Document.accept(contact, raw)
    dav = contact.dav |> Ecto.Changeset.change(document: document) |> Repo.update!()
    %{contact | dav: dav}
  end

  defp insert_field(contact, type, value, label),
    do:
      Repo.insert!(%ContactField{
        account_id: contact.account_id,
        contact_id: contact.id,
        contact_field_type_id: type,
        value: value,
        label: label
      })

  defp card(lines),
    do:
      Enum.join(
        ["BEGIN:VCARD", "VERSION:4.0", "FN:Contact", "N:;Contact;;;" | lines] ++ ["END:VCARD", ""],
        "\r\n"
      )
end
