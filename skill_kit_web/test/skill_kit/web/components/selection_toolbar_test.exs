defmodule SkillKit.Web.Components.SelectionToolbarTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SkillKit.Web.Components.SelectionToolbar

  test "renders ask agent button when selection exists" do
    html =
      render_component(&SelectionToolbar.selection_toolbar/1,
        selection: %{text: "some text", top: 100, left: 200}
      )

    assert html =~ "Ask agent"
  end

  test "not rendered when no selection" do
    html = render_component(&SelectionToolbar.selection_toolbar/1, selection: nil)
    refute html =~ "Ask agent"
  end
end
