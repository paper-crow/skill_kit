defmodule SkillKit.Web.IntegrationTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  alias SkillKit.Skill
  alias SkillKit.ToolExecution
  alias SkillKit.Web.DocumentKit

  @tmp_dir "test/tmp/integration_test"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "welcome.md"), "# Welcome\n\nWhat are you building?")
    Application.put_env(:skill_kit_web, :docs_root, @tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
  end

  test "full editor workflow: open, browse, switch documents", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Welcome"
    assert html =~ "What are you building?"

    view |> element(~s{button[phx-value-panel="docs"]}) |> render_click()
    assert render(view) =~ "welcome.md"

    view |> element(~s{button[phx-value-panel="docs"]}) |> render_click()
  end

  test "DocumentKit lists project files" do
    {:ok, [kit]} = DocumentKit.list_kits([])
    assert kit.name == "docs"
    assert length(kit.skills) == 7
  end

  test "DocumentKit Tool can read files" do
    execution = %ToolExecution{
      skill: %Skill{name: "docs:read"},
      tool: SkillKit.Web.DocumentKit.Tool,
      input: %{"path" => "welcome.md"},
      context: %{docs_root: @tmp_dir},
      status: :running
    }

    assert {:ok, content} = SkillKit.Web.DocumentKit.Tool.execute(execution)
    assert content =~ "Welcome"
  end
end
