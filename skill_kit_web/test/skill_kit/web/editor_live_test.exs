defmodule SkillKit.Web.EditorLiveTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  @tmp_dir "test/tmp/editor_live_test"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    File.mkdir_p!(Path.join(@tmp_dir, "guides"))
    File.write!(Path.join(@tmp_dir, "guides/welcome.md"), "# Welcome\n\nDescribe your project.")
    File.write!(Path.join(@tmp_dir, "guides/features.md"), "# Features\n\nList features here.")
    Application.put_env(:skill_kit_web, :project_root, @tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
  end

  test "renders editor with document list", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "welcome.md"
    assert html =~ "features.md"
  end

  test "opens a different document", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element(~s{button[phx-value-path="guides/welcome.md"]}) |> render_click()
    assert render(view) =~ "Welcome"
  end

  test "toggles document tree drawer", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element(~s{button[phx-value-panel="docs"]}) |> render_click()
    assert render(view) =~ "Documents"
  end
end
