defmodule SkillKit.Web.ChatIntegrationTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  @tmp_dir Path.expand("../../tmp/chat_integration_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "welcome.md"), "# Welcome\n\nDescribe your project.")
    Application.put_env(:skill_kit_web, :docs_root, @tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
  end

  test "chat is always visible with input", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Type your message"
  end

  test "sending a message adds it to chat", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> form("form", %{message: "What is this project about?"}) |> render_submit()
    html = render(view)
    assert html =~ "What is this project about?"
  end
end
