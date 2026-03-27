defmodule SkillKit.Web.Components.ThemeToggleTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SkillKit.Web.Components.ThemeToggle

  test "renders toggle button" do
    html = render_component(&ThemeToggle.theme_toggle/1, %{})
    assert html =~ "theme-toggle"
  end
end
