defmodule SkillKit.Web.Components.SidebarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SkillKit.Web.Components.Sidebar

  test "renders all sidebar icons" do
    html = render_component(&Sidebar.sidebar/1, active: :docs)

    assert html =~ "Documents"
    assert html =~ "Chat"
    assert html =~ "Build"
    assert html =~ "App"
  end

  test "marks the active icon" do
    html = render_component(&Sidebar.sidebar/1, active: :chat)

    assert html =~ ~s(phx-value-panel="chat")
  end
end
