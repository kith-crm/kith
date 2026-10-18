defmodule KithWeb.KithUIAvatarTest do
  use KithWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KithWeb.KithUI

  test "with src: hooked image plus hidden initials fallback" do
    html = render_component(&KithUI.avatar/1, id: "a1", src: "/uploads/x.png", name: "Mona Vale")

    assert html =~ ~s(id="a1")
    assert html =~ ~s(phx-hook="ImgFallback")
    assert html =~ "data-fallback-img"
    assert html =~ "group-data-[img-failed]:inline-flex"
    assert html =~ "MV"
  end

  test "without src: initials only, no hook" do
    html = render_component(&KithUI.avatar/1, name: "Mona Vale")
    refute html =~ "phx-hook"
    assert html =~ "MV"
  end

  test "src without id raises" do
    assert_raise ArgumentError, ~r/needs an :id/, fn ->
      render_component(&KithUI.avatar/1, src: "/uploads/x.png", name: "Mona Vale")
    end
  end
end
