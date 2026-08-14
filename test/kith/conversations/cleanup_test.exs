defmodule Kith.Conversations.CleanupTest do
  use Kith.DataCase, async: true

  alias Kith.Conversations.{Cleanup, Conversation, Message}
  alias Kith.Repo

  import Ecto.Query
  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  setup do
    target = user_fixture()
    other = user_fixture()
    target_contact = contact_fixture(target.account_id)
    other_contact = contact_fixture(other.account_id)

    %{
      target_account: target.account_id,
      target_user: target.id,
      target_contact: target_contact,
      other_account: other.account_id,
      other_user: other.id,
      other_contact: other_contact
    }
  end

  test "wipes conversations (CASCADE messages) for target; leaves other untouched", ctx do
    target_conv = insert_conversation!(ctx.target_account, ctx.target_user, ctx.target_contact.id)
    other_conv = insert_conversation!(ctx.other_account, ctx.other_user, ctx.other_contact.id)

    insert_message!(target_conv.id, ctx.target_account)
    insert_message!(other_conv.id, ctx.other_account)

    assert :ok = Cleanup.wipe_for_account(ctx.target_account)

    assert count_for(Conversation, ctx.target_account) == 0
    assert count_for(Message, ctx.target_account) == 0

    assert count_for(Conversation, ctx.other_account) == 1
    assert count_for(Message, ctx.other_account) == 1
  end

  test "is idempotent on empty account", ctx do
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
    assert :ok = Cleanup.wipe_for_account(ctx.target_account)
  end

  defp insert_conversation!(account_id, user_id, contact_id) do
    Repo.insert!(%Conversation{
      account_id: account_id,
      creator_id: user_id,
      contact_id: contact_id,
      subject: "test",
      platform: "other",
      status: "active"
    })
  end

  defp insert_message!(conversation_id, account_id) do
    Repo.insert!(%Message{
      account_id: account_id,
      conversation_id: conversation_id,
      body: "hi",
      direction: "sent",
      sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp count_for(schema, account_id) do
    Repo.aggregate(from(s in schema, where: s.account_id == ^account_id), :count)
  end
end
