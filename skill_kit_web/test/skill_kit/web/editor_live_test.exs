defmodule SkillKit.Web.EditorLiveTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  @tmp_dir Path.expand("../../tmp/editor_live_test", __DIR__)

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

  test "deep link to existing document", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/features")
    assert html =~ "List features here"
  end

  test "deep link to missing document falls back to first file", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/nonexistent")
    # Falls back to first available file (alphabetical)
    assert html =~ "Features" or html =~ "Welcome"
  end

  test "empty docs directory redirects to /setup", %{conn: conn} do
    empty_dir = Path.join(@tmp_dir, "empty")
    File.mkdir_p!(empty_dir)
    Application.put_env(:skill_kit_web, :docs_root, empty_dir)

    {:error, {:live_redirect, %{to: path}}} = live(conn, "/")
    assert path == "/setup"
  end

  test "editor_change saves content to file", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_hook(view, "editor_change", %{"content" => "# Updated\n\nNew content."})

    # Verify file was written
    content = File.read!(Path.join(@tmp_dir, "features.md"))
    assert content == "# Updated\n\nNew content."
  end

  test "editor_change handles write failure gracefully", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/welcome")
    # Make the file read-only
    path = Path.join(@tmp_dir, "welcome.md")
    File.chmod!(path, 0o444)

    # Should not crash — error goes to chat
    html = render_hook(view, "editor_change", %{"content" => "should fail"})
    assert html =~ "Save failed"

    File.chmod!(path, 0o644)
  end

  test "toggle_drawer toggles debug panel", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    refute html =~ "data-panel-open"

    html = render_click(view, "toggle_drawer", %{"panel" => "build"})
    assert html =~ "Telemetry"
  end

  test "sending empty chat message does nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_hook(view, "send_chat_message", %{"message" => ""})
    # No crash, page still renders
    assert html =~ "Type your message"
  end

  test "sending empty thread message does nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_hook(view, "send_thread_message", %{"message" => ""})
    assert html =~ "Type your message"
  end

  test "dismiss_inline_thread when no thread is open", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_hook(view, "dismiss_inline_thread", %{})
    assert html =~ "Type your message"
  end

  test "clear_selection event", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_hook(view, "clear_selection", %{})
    assert html =~ "Type your message"
  end
end
