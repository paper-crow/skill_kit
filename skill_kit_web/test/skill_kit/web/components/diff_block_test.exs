defmodule SkillKit.Web.Components.DiffBlockTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SkillKit.Web.Components.DiffBlock

  test "renders old and new content" do
    html =
      render_component(&DiffBlock.diff_block/1,
        diff: %{path: "auth.md", old_content: "old text", new_content: "new text"}
      )

    assert html =~ "old text"
    assert html =~ "new text"
  end

  test "renders accept and reject buttons" do
    html =
      render_component(&DiffBlock.diff_block/1,
        diff: %{path: "auth.md", old_content: "old", new_content: "new"}
      )

    assert html =~ "Accept"
    assert html =~ "Reject"
  end

  test "not rendered when diff is nil" do
    html = render_component(&DiffBlock.diff_block/1, diff: nil)
    refute html =~ "Accept"
  end

  test "shows the file path" do
    html =
      render_component(&DiffBlock.diff_block/1,
        diff: %{path: "guides/auth.md", old_content: "old", new_content: "new"}
      )

    assert html =~ "guides/auth.md"
  end
end
