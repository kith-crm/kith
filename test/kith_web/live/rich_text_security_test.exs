defmodule KithWeb.RichTextSecurityTest do
  use KithWeb.ConnCase, async: true

  import Kith.Factory
  import Phoenix.LiveViewTest

  alias Kith.Repo

  @payload ~s|<div onclick="alert(1)">Legacy <strong>formatting</strong><br>Second line</div><img src=x onerror="alert(2)"><a href="javascript:alert(3)">bad link</a>|

  setup :register_and_log_in_user

  setup %{user: user} do
    account = Repo.get!(Kith.Accounts.Account, user.account_id)
    %{account: account}
  end

  test "journal writes persist only the allowed rich text", %{account: account, user: user} do
    assert {:ok, entry} =
             Kith.Journal.create_entry(account.id, user.id, %{
               content: @payload,
               occurred_at: DateTime.utc_now(:second)
             })

    entry |> Repo.reload!() |> Map.fetch!(:content) |> assert_safe_rich_text()
  end

  test "legacy note rows cannot inject active HTML through the notes component", %{
    account: account,
    user: user
  } do
    contact = insert(:contact, account: account)
    # Factory insertion bypasses the changeset, representing a pre-fix row.
    insert(:note, account: account, contact: contact, author: user, body: @payload)

    html =
      render_component(KithWeb.ContactLive.NotesListComponent,
        id: "legacy-notes",
        contact_id: contact.id,
        account_id: account.id,
        current_user_id: user.id,
        can_edit: true
      )

    assert_safe_rich_text(html)
  end

  test "legacy journal rows are scrubbed on the actual LiveView render", %{
    conn: conn,
    account: account,
    user: user
  } do
    insert(:journal_entry, account: account, author: user, content: @payload)
    {:ok, view, _html} = live(conn, ~p"/journal")
    html = view |> element(".prose") |> render()
    assert_safe_rich_text(html)
  end

  defp assert_safe_rich_text(html) do
    assert html =~ "<strong>formatting</strong>"
    assert html =~ "Second line"
    refute html =~ "onclick="
    refute html =~ "onerror="
    refute html =~ "javascript:"
    refute html =~ "<img"
  end
end
