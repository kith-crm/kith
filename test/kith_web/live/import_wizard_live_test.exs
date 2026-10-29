defmodule KithWeb.ImportWizardLiveTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  describe "handle_info/2" do
    test "does not crash on :sync_complete broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/import")
      send(view.pid, {:sync_complete, %{"status" => "completed", "synced" => 0}})
      # If the process is still alive and renders without error, the fix is working
      assert render(view) =~ "Import Contacts"
    end
  end

  describe "import complete summary" do
    test "uses the Monica wording for a Monica import and shows its errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/import")
      render_click(view, "set_source", %{"source" => "monica_api"})

      send(
        view.pid,
        {:import_complete, %{imported: 2, skipped: 3, error_count: 4, errors: ["boom"]}}
      )

      html = render(view)

      assert html =~ "skipped (already imported from Monica, or deleted)"
      assert has_element?(view, "#import-errors", ~r/4\s+errors/)
    end

    test "uses neutral wording for a vCard import", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/import")

      send(
        view.pid,
        {:import_complete, %{imported: 2, skipped: 3, error_count: 3, errors: ["bad"]}}
      )

      html = render(view)

      refute html =~ "already imported from Monica"
      assert has_element?(view, "#import-skipped", ~r/3\s+skipped/)
      refute has_element?(view, "#import-errors")
    end

    test "omits the skipped line when only errors occurred (Monica)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/import")
      render_click(view, "set_source", %{"source" => "monica_api"})

      send(
        view.pid,
        {:import_complete, %{imported: 0, skipped: 0, error_count: 1, errors: ["boom"]}}
      )

      html = render(view)

      refute html =~ "already imported from Monica"
      assert has_element?(view, "#import-errors", ~r/1\s+error /)
      refute has_element?(view, "#import-skipped")
    end
  end
end
