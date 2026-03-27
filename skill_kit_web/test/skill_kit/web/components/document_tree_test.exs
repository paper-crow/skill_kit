defmodule SkillKit.Web.Components.DocumentTreeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SkillKit.Web.Components.DocumentTree

  test "renders file list grouped by directory" do
    files = ["guides/auth.md", "guides/tasks.md", "readme.md"]

    html =
      render_component(&DocumentTree.document_tree/1,
        files: files,
        current_path: "readme.md",
        open: true
      )

    assert html =~ "guides"
    assert html =~ "auth.md"
    assert html =~ "tasks.md"
    assert html =~ "readme.md"
  end

  test "highlights the current file" do
    files = ["readme.md", "guide.md"]

    html =
      render_component(&DocumentTree.document_tree/1,
        files: files,
        current_path: "readme.md",
        open: true
      )

    assert html =~ "readme.md"
  end

  test "hidden when not open" do
    html =
      render_component(&DocumentTree.document_tree/1,
        files: ["readme.md"],
        current_path: nil,
        open: false
      )

    assert html =~ "hidden"
  end
end
