defmodule Kith.DAV.RelationshipsTest do
  use Kith.DataCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Contacts.{Relationship, RelationshipType}
  alias Kith.DAV.{Relationships, Store, UID}
  alias Kith.VCard.Document

  setup do
    account = user_fixture().account_id
    a = contact_fixture(account)
    b = contact_fixture(account)
    hidden = contact_fixture(account, %{is_archived: true})
    Store.ensure_rows(account)
    %{account: account, a: a, b: b, hidden: hidden}
  end

  test "projects both directions with safe standard inverse categories", c do
    edge = edge!(c.b, c.a, trusted_type!("parent"))

    assert [forward] = Relationships.project(c.b)
    assert forward.type == "parent"
    assert forward.label == "Parent"
    assert forward.bindings == [%{id: edge.id, direction: :forward}]
    assert [reverse] = Relationships.project(c.a)
    assert reverse.type == "child"
    assert reverse.related_contact.id == c.b.id
    assert reverse.related_contact.dav.uid == dav(c.b).uid
    assert reverse.value == UID.urn(dav(c.b).uid)
    assert reverse.relationship_type == %{name: "Child"}
    refute Map.has_key?(reverse.related_contact, :description)
    assert reverse.id =~ ~r/^rel-[a-f0-9]{64}$/
    refute reverse.id == edge.id
  end

  test "custom names cannot classify relations or leak subtype labels", c do
    type = custom_type!(c.account, "Private secret subtype", "Spouse")
    edge = edge!(c.a, c.b, type)
    assert [view] = Relationships.project(c.a)
    assert view.type == "contact"
    assert view.label == "Contact"
    assert view.relationship_type.name == "Contact"

    assert {:ok, result} = reconcile(c.a, [%{value: view.value, type: "contact"}])
    assert result.client_only == []
    assert Repo.get!(Relationship, edge.id).relationship_type_id == type.id
    assert Repo.get!(RelationshipType, type.id).name == "Private secret subtype"
  end

  test "equivalent reciprocal rows collapse and unchanged PUT preserves both IDs", c do
    forward = edge!(c.a, c.b, trusted_type!("parent"))
    reverse = edge!(c.b, c.a, trusted_type!("child"))
    assert [view] = Relationships.project(c.a)
    assert view.type == "parent"
    assert Enum.map(view.bindings, & &1.id) == Enum.sort([forward.id, reverse.id])

    assert {:ok, _} = reconcile(c.a, [%{value: view.value, type: "parent"}])
    assert Repo.get!(Relationship, forward.id)
    assert Repo.get!(Relationship, reverse.id)
  end

  test "omitting a collapsed visible edge deletes its represented native rows", c do
    forward = edge!(c.a, c.b, trusted_type!("parent"))
    reverse = edge!(c.b, c.a, trusted_type!("child"))
    assert {:ok, result} = reconcile(c.a, [])
    assert Enum.sort(result.affected_contact_ids) == Enum.sort([c.a.id, c.b.id])
    refute Repo.get(Relationship, forward.id)
    refute Repo.get(Relationship, reverse.id)
  end

  test "hidden targets never project and their native edges survive omission", c do
    edge = edge!(c.a, c.hidden, trusted_type!("friend"))
    assert Relationships.project(c.a) == []
    assert Relationships.project(c.hidden) == []
    entry = %{value: UID.urn(dav(c.hidden).uid), type: "friend"}
    assert {:ok, result} = reconcile(c.a, [entry])
    assert result.suppressed == [entry]
    assert result.client_only == []
    assert Repo.get!(Relationship, edge.id)
    assert {:ok, _} = reconcile(c.a, [])
    assert Repo.get!(Relationship, edge.id)
  end

  test "unknown URIs and text are client-only without matching display names", c do
    entries = [
      %{value: "https://example.com/person", type: "friend"},
      %{value: c.b.display_name, type: "friend", value_type: :text},
      %{value: UID.urn(dav(c.b).uid), type: "friend", value_type: "text"}
    ]

    assert {:ok, result} = reconcile(c.a, entries)
    assert result.client_only == entries
    assert result.suppressed == []
    assert Relationships.project(c.a) == []
  end

  test "new known relations use deterministic trusted category destinations", c do
    _impostor = custom_type!(c.account, "Friend", "Friend")
    entries = [%{value: UID.urn(dav(c.b).uid), type: "friend"}]
    assert {:ok, result} = reconcile(c.a, entries)
    assert Enum.sort(result.affected_contact_ids) == Enum.sort([c.a.id, c.b.id])
    assert [edge] = Repo.all(from(r in Relationship, where: r.contact_id == ^c.a.id))
    assert edge.relationship_type_id == trusted_type!("friend").id

    assert {:ok, _} = reconcile(c.a, entries ++ entries)
    assert [same] = Repo.all(from(r in Relationship, where: r.contact_id == ^c.a.id))
    assert same.id == edge.id
  end

  test "unrecognized client categories bind generic trusted Contact", c do
    assert {:ok, _} = reconcile(c.a, [%{value: UID.urn(dav(c.b).uid), type: "secret subtype"}])
    assert [view] = Relationships.project(c.a)
    assert view.type == "contact"
    assert [binding] = view.bindings
    assert Repo.get!(Relationship, binding.id).relationship_type_id == trusted_type!("contact").id
  end

  test "foreign account UUIDs remain unresolved and malformed cross-account edges are excluded",
       c do
    foreign = contact_fixture(user_fixture().account_id)
    Store.ensure_rows(foreign.account_id)
    edge = edge!(c.a, foreign, trusted_type!("friend"))
    assert Relationships.project(c.a) == []
    entry = %{value: UID.urn(dav(foreign).uid), type: "friend"}
    assert {:ok, result} = reconcile(c.a, [entry])
    assert result.client_only == [entry]
    assert Repo.get!(Relationship, edge.id)
  end

  test "document filtering suppresses hidden references and same-group companions only", c do
    hidden_uid = UID.urn(dav(c.hidden).uid)

    source =
      Enum.join(
        [
          "BEGIN:VCARD",
          "VERSION:4.0",
          "FN:Name",
          "item-a.RELATED;TYPE=friend:" <> hidden_uid,
          "item-a.X-ABRELATEDNAMES:Never expose hidden name",
          "item-a.X-ABLabel:Friend",
          "RELATED;VALUE=text:" <> hidden_uid,
          "RELATED;VALUE=uri:https://example.com/external",
          "item-b.X-ABRELATEDNAMES:Unresolved text",
          "END:VCARD",
          ""
        ],
        "\r\n"
      )

    assert {:ok, document} = Document.parse(source)
    properties = Relationships.safe_document_properties(c.a, document.properties)
    refute Enum.any?(properties, &(&1.group == "item-a"))
    assert Enum.any?(properties, &(&1.group == "item-b"))
    assert Enum.count(properties, &(&1.normalized_name == "RELATED")) == 2
  end

  test "conflicting VALUE parameters cannot bypass hidden-target suppression", c do
    uid = UID.urn(dav(c.hidden).uid)

    raw =
      "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Name\r\nRELATED;VALUE=text;VALUE=uri:" <>
        uid <> "\r\nEND:VCARD\r\n"

    assert {:ok, document} = Document.parse(raw)
    safe = Relationships.safe_document_properties(c.a, document.properties)
    refute Enum.any?(safe, &(&1.normalized_name == "RELATED"))
  end

  test "missing canonical destination rolls back before removing existing edges", c do
    edge = edge!(c.a, c.b, trusted_type!("friend"))
    Repo.delete!(trusted_type!("colleague"))

    assert {:error, {:missing_shared_relationship_type, "colleague"}} =
             reconcile(c.a, [%{value: UID.urn(dav(c.b).uid), type: "colleague"}])

    assert Repo.get!(Relationship, edge.id)
  end

  test "read snapshot cache restores after exceptions and does not leak to later writes", c do
    assert_raise RuntimeError, "snapshot probe", fn ->
      Relationships.with_snapshot(c.account, fn ->
        assert Relationships.project(c.a) == []
        raise "snapshot probe"
      end)
    end

    edge = edge!(c.a, c.b, trusted_type!("friend"))
    assert [view] = Relationships.project(c.a)
    assert view.bindings == [%{id: edge.id, direction: :forward}]
  end

  test "nested account read caches remain account scoped and restore the outer snapshot", c do
    edge!(c.a, c.b, trusted_type!("friend"))
    foreign = contact_fixture(user_fixture().account_id)
    Store.ensure_rows(foreign.account_id)

    Relationships.with_snapshot(c.account, fn ->
      assert [outer] = Relationships.project(c.a)

      Relationships.with_snapshot(foreign.account_id, fn ->
        assert Relationships.project(foreign) == []
      end)

      assert Relationships.project(c.a) == [outer]
    end)
  end

  defp reconcile(contact, entries) do
    case Store.transaction(contact.account_id, fn ->
           case Relationships.reconcile(contact, entries) do
             {:ok, result} -> result
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dav(contact), do: Repo.get!(Kith.DAV.ContactDav, contact.id)

  defp trusted_type!(key) do
    Repo.one(from(t in RelationshipType, where: is_nil(t.account_id) and t.system_key == ^key)) ||
      Repo.insert!(%RelationshipType{system_key: key, name: key, reverse_name: key})
  end

  defp custom_type!(account, name, reverse_name) do
    Repo.insert!(%RelationshipType{account_id: account, name: name, reverse_name: reverse_name})
  end

  defp edge!(owner, target, type) do
    Repo.insert!(%Relationship{
      account_id: owner.account_id,
      contact_id: owner.id,
      related_contact_id: target.id,
      relationship_type_id: type.id
    })
  end
end
