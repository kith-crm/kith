defmodule KithWeb.KithUIReminderRowTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KithWeb.KithUI

  defp row(type) do
    render_component(&KithUI.reminder_row/1,
      reminder: %{type: type, title: "T", date: ~D[2026-04-15]}
    )
  end

  test "a first_met reminder uses the sparkles icon" do
    assert row("first_met") =~ "hero-sparkles"
  end

  test "known types keep their icons and unknown types fall back to the bell" do
    assert row("birthday") =~ "hero-cake"
    assert row("recurring") =~ "hero-bell"
  end
end
