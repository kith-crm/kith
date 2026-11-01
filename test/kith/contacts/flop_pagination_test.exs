defmodule Kith.Contacts.FlopPaginationTest do
  use Kith.DataCase, async: true

  alias Kith.Contacts
  alias Kith.Contacts.Contact

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    user = user_fixture()
    %{account_id: user.account_id}
  end

  test "tied names paginate by ascending ID without missing or duplicate contacts", ctx do
    contacts =
      for _ <- 1..7, do: contact_fixture(ctx.account_id, %{first_name: "Same", last_name: "Name"})

    expected = Enum.map(contacts, & &1.id) |> Enum.sort()

    pages =
      for offset <- [0, 3, 6] do
        assert {:ok, entries, meta} =
                 Contacts.list_contacts_flop(ctx.account_id, %{
                   "offset" => offset,
                   "limit" => 3,
                   "order_by" => ["display_name"],
                   "order_directions" => ["desc"]
                 })

        assert meta.total_count == 7
        Enum.map(entries, & &1.id)
      end

    assert List.flatten(pages) == expected
  end

  test "search and duplicate tag joins preserve name ordering and tenant filters", ctx do
    zulu = contact_fixture(ctx.account_id, %{first_name: "Zulu", last_name: "Match"})
    alpha = contact_fixture(ctx.account_id, %{first_name: "Alpha", last_name: "Match"})
    other = user_fixture()
    contact_fixture(other.account_id, %{first_name: "Aardvark", last_name: "Match"})

    {:ok, first_tag} = Contacts.create_tag(ctx.account_id, %{name: "First"})
    {:ok, second_tag} = Contacts.create_tag(ctx.account_id, %{name: "Second"})

    for contact <- [zulu, alpha], tag <- [first_tag, second_tag] do
      assert {1, nil} = Contacts.tag_contact(contact, tag)
    end

    for options <- [
          [search: "Match"],
          [tag_ids: [first_tag.id, second_tag.id]],
          [search: "Match", tag_ids: [first_tag.id, second_tag.id]]
        ] do
      assert {:ok, [first], meta} =
               Contacts.list_contacts_flop(ctx.account_id, %{limit: 1}, options)

      assert first.id == alpha.id
      assert meta.total_count == 2
      assert Enum.sort(Enum.map(first.tags, & &1.id)) == [first_tag.id, second_tag.id]

      assert {:ok, [second], _} =
               Contacts.list_contacts_flop(ctx.account_id, %{limit: 1, offset: 1}, options)

      assert second.id == zulu.id
    end
  end

  test "archive, favorite, deceased and deleted restrictions remain effective", ctx do
    active = contact_fixture(ctx.account_id)

    archived =
      contact_fixture(ctx.account_id)
      |> change(is_archived: true, favorite: true)
      |> Repo.update!()

    contact_fixture(ctx.account_id) |> change(deceased: true) |> Repo.update!()

    contact_fixture(ctx.account_id)
    |> change(deleted_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:ok, [result], _} = Contacts.list_contacts_flop(ctx.account_id, %{})
    assert result.id == active.id

    assert {:ok, [result], _} =
             Contacts.list_contacts_flop(ctx.account_id, %{},
               archived: :only,
               favorites_only: true
             )

    assert result.id == archived.id

    assert {:ok, entries, _} =
             Contacts.list_contacts_flop(ctx.account_id, %{}, archived: true, deceased: true)

    assert length(entries) == 3
  end

  test "validates saved parameters, allowed fields and the maximum limit", ctx do
    contact_fixture(ctx.account_id)

    assert {:ok, [_], meta} =
             Contacts.list_contacts_flop(ctx.account_id, %{"limit" => "100", "offset" => "0"})

    assert meta.flop.limit == 100

    for params <- [
          %{"limit" => "101"},
          %{"offset" => "-1"},
          %{"order_by" => ["account_id"]},
          %{"limit" => "invalid"},
          %{"filters" => [%{"field" => "favorite", "op" => "==", "value" => true}]}
        ] do
      assert {:error, _} = Contacts.list_contacts_flop(ctx.account_id, params)
    end

    assert Flop.allowed_fields(:sortable, for: Contact) == [
             :display_name,
             :inserted_at,
             :last_talked_to
           ]

    assert Flop.get_option(:max_limit, for: Contact) == 100
  end
end
