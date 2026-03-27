defmodule SkillKit.Web.Components.DocumentTreeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SkillKit.Web.Components.DocumentTree

  test "renders file list grouped by directory" do
    files = [
      %{path: "guides/auth.md", title: "Authentication"},
      %{path: "guides/tasks.md", title: "Tasks"},
      %{path: "readme.md", title: "Readme"}
    ]

    html =
      render_component(&DocumentTree.document_tree/1,
        files: files,
        current_path: "readme.md",
        open: true
      )

    assert html =~ "guides"
    assert html =~ "Authentication"
    assert html =~ "Tasks"
    assert html =~ "Readme"
  end

  test "highlights the current file" do
    files = [
      %{path: "readme.md", title: "Readme"},
      %{path: "guide.md", title: "Guide"}
    ]

    html =
      render_component(&DocumentTree.document_tree/1,
        files: files,
        current_path: "readme.md",
        open: true
      )

    assert html =~ "Readme"
  end

  test "hidden when not open" do
    html =
      render_component(&DocumentTree.document_tree/1,
        files: [%{path: "readme.md", title: "Readme"}],
        current_path: nil,
        open: false
      )

    assert html =~ "hidden"
  end
end
