defmodule SkillKit.Web.Components.EditorSurfaceTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SkillKit.Web.Components.EditorSurface

  test "renders document content" do
    html =
      render_component(&EditorSurface.editor_surface/1,
        content: "# Hello World\n\nSome content here.",
        path: "guides/hello.md",
        threads: []
      )

    assert html =~ "Hello World"
    assert html =~ "Some content here"
  end

  test "renders file path breadcrumb" do
    html =
      render_component(&EditorSurface.editor_surface/1,
        content: "# Doc",
        path: "guides/auth.md",
        threads: []
      )

    assert html =~ "guides/auth.md"
  end

  test "renders empty state when no content" do
    html = render_component(&EditorSurface.editor_surface/1, content: nil, path: nil, threads: [])
    assert html =~ "No document open"
  end
end
