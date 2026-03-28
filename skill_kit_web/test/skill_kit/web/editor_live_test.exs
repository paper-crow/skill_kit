defmodule SkillKit.Web.EditorLiveTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  @tmp_dir "test/tmp/editor_live_test"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "welcome.md"), "# Welcome\n\nDescribe your project.")
    File.write!(Path.join(@tmp_dir, "features.md"), "# Features\n\nList features here.")
    Application.put_env(:skill_kit_web, :docs_root, @tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
  end

  test "renders editor with document list and chat", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Welcome"
    assert html =~ "Features"
    assert html =~ "Type your message"
  end

  test "opens a different document", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element(~s{button[phx-value-path="welcome.md"]}) |> render_click()
    assert render(view) =~ "Welcome"
  end

  test "document tree is always visible", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Welcome"
    assert html =~ "Features"
  end
end
