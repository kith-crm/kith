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
end
