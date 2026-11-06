defmodule Kith.Contacts.MergeSummaryTest do
  use Kith.DataCase, async: false

  import Ecto.Query

  alias Kith.Contacts.MergeSummary
  alias Kith.{AccountsFixtures, ContactsFixtures}

  setup do
    ContactsFixtures.seed_reference_data!()
    user = AccountsFixtures.user_fixture()

    email_type =
      Repo.one!(
        from(t in Kith.Contacts.ContactFieldType, where: like(t.protocol, "mailto%"), limit: 1)
      )

    a = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Sarah"})
    b = ContactsFixtures.contact_fixture(user.account_id, %{first_name: "Sarah"})

    %{user: user, account_id: user.account_id, email_type: email_type, a: a, b: b}
  end

  test "combines contact fields and marks the repeat as a duplicate", ctx do
    ContactsFixtures.contact_field_fixture(ctx.a, ctx.email_type.id, %{"value" => "s@example.com"})

    ContactsFixtures.contact_field_fixture(ctx.b, ctx.email_type.id, %{"value" => "s@example.com"})

    ContactsFixtures.contact_field_fixture(ctx.b, ctx.email_type.id, %{
      "value" => "other@example.com"
    })

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert length(summary.contact_fields) == 3
    assert Enum.count(summary.contact_fields, & &1.duplicate?) == 1

    kept = Enum.reject(summary.contact_fields, & &1.duplicate?)
    assert Enum.sort(Enum.map(kept, & &1.value)) == ["other@example.com", "s@example.com"]
  end

  test "the first occurrence is kept and the later one marked duplicate", ctx do
    first =
      ContactsFixtures.contact_field_fixture(ctx.a, ctx.email_type.id, %{
        "value" => "s@example.com"
      })

    second =
      ContactsFixtures.contact_field_fixture(ctx.b, ctx.email_type.id, %{
        "value" => "s@example.com"
      })

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert Enum.find(summary.contact_fields, &(&1.id == first.id)).duplicate? == false
    assert Enum.find(summary.contact_fields, &(&1.id == second.id)).duplicate? == true
  end

  test "addresses dedupe on line1 and postal code", ctx do
    ContactsFixtures.address_fixture(ctx.a, %{"line1" => "1 Main St", "postal_code" => "94110"})

    ContactsFixtures.address_fixture(ctx.b, %{"line1" => "  1 main st ", "postal_code" => "94110"})

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert Enum.count(summary.addresses, & &1.duplicate?) == 1
  end

  test "addresses with no line1 or postal code are never collapsed into each other", ctx do
    ContactsFixtures.address_fixture(ctx.a, %{
      "line1" => nil,
      "postal_code" => nil,
      "city" => "Paris"
    })

    ContactsFixtures.address_fixture(ctx.b, %{
      "line1" => nil,
      "postal_code" => nil,
      "city" => "Tokyo"
    })

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert Enum.count(summary.addresses, & &1.duplicate?) == 0
  end

  # Kith.Contacts.Merge compares these columns through `coalesce(col, '')`, so
  # a NULL line1 and an empty-string line1 are the same value to `:dedupe_owned`.
  # The summary key has to agree, or a caller expanding a dropped entry by key
  # would miss the other side of the pair and the dropped value would survive.
  # The empty string is written directly: `Address`'s changeset casts `""` to
  # nil, so a blank line1 only reaches the column through a bulk insert.
  test "an address with a nil line1 keys the same as one with an empty line1", ctx do
    ContactsFixtures.address_fixture(ctx.a, %{"line1" => nil, "postal_code" => "94110"})
    blank = ContactsFixtures.address_fixture(ctx.b, %{"line1" => nil, "postal_code" => "94110"})

    Repo.update_all(from(a in Kith.Contacts.Address, where: a.id == ^blank.id),
      set: [line1: ""]
    )

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert [first, second] = summary.addresses
    assert first.key == second.key
    assert Enum.count(summary.addresses, & &1.duplicate?) == 1
  end

  test "aliases are unioned across members", ctx do
    Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.a.id),
      set: [aliases: ["Sarah K."]]
    )

    Repo.update_all(from(c in Kith.Contacts.Contact, where: c.id == ^ctx.b.id),
      set: [aliases: ["Sarah K.", "SK"]]
    )

    a = Repo.get!(Kith.Contacts.Contact, ctx.a.id)
    b = Repo.get!(Kith.Contacts.Contact, ctx.b.id)

    summary = MergeSummary.build([a, b])

    assert Enum.map(summary.aliases, & &1.value) |> Enum.sort() == ["SK", "Sarah K."]
  end

  test "history counts every type across every member", ctx do
    ContactsFixtures.note_fixture(ctx.a, ctx.user.id)
    ContactsFixtures.note_fixture(ctx.b, ctx.user.id)
    ContactsFixtures.document_fixture(ctx.b)

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert summary.history.notes == 2
    assert summary.history.documents == 1
    assert summary.history.calls == 0
  end

  # `Merge`'s `remap_relationships/4` rewrites `related_contact_id` as well as
  # `contact_id`, so a member that is only ever the target of relationships
  # still has rows moved onto the survivor. Counting the first endpoint alone
  # reports 0 for it and understates the "records move to the primary" line.
  test "history counts relationships pointing at a member as well as from it", ctx do
    [friend_type | _] = Repo.all(from(rt in "relationship_types", select: rt.id, limit: 1))

    outsider =
      ContactsFixtures.contact_fixture(ctx.user.account_id, %{first_name: "Outsider"})

    # Neither member is the `contact_id` of either row.
    ContactsFixtures.relationship_fixture(outsider, ctx.a, friend_type)
    ContactsFixtures.relationship_fixture(outsider, ctx.b, friend_type)

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert summary.history.relationships == 2
  end

  test "history counts a relationship between two members once", ctx do
    [friend_type | _] = Repo.all(from(rt in "relationship_types", select: rt.id, limit: 1))

    ContactsFixtures.relationship_fixture(ctx.a, ctx.b, friend_type)

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert summary.history.relationships == 1
  end

  # `Kith.Contacts.Merge`'s dedupe runs `lower(btrim(value))`, and one-argument
  # `btrim` strips SPACES ONLY. `String.trim/1` strips every Unicode whitespace
  # character. Trimming with it would make a tab-prefixed value read as
  # "duplicate · dropped" on screen while the engine keeps both rows, and a
  # caller expanding a dropped entry over everything sharing its key would then
  # drop a value the user never excluded.
  test "a tab-prefixed value is not a duplicate, matching the engine's btrim", ctx do
    ContactsFixtures.contact_field_fixture(ctx.a, ctx.email_type.id, %{"value" => "s@example.com"})

    ContactsFixtures.contact_field_fixture(ctx.b, ctx.email_type.id, %{
      "value" => "\ts@example.com"
    })

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert Enum.count(summary.contact_fields, & &1.duplicate?) == 0
    assert summary.contact_fields |> Enum.map(& &1.key) |> Enum.uniq() |> length() == 2
  end

  test "a space-padded value is still a duplicate, matching the engine's btrim", ctx do
    ContactsFixtures.contact_field_fixture(ctx.a, ctx.email_type.id, %{"value" => "s@example.com"})

    ContactsFixtures.contact_field_fixture(ctx.b, ctx.email_type.id, %{
      "value" => "  s@example.com  "
    })

    summary = MergeSummary.build([ctx.a, ctx.b])

    assert Enum.count(summary.contact_fields, & &1.duplicate?) == 1
  end
end
