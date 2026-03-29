defmodule SkillKit.Web.InlineThreadIntegrationTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  @tmp_dir "test/tmp/inline_thread_test"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "doc.md"), "# Test\n\nSome content here.")
    Application.put_env(:skill_kit_web, :docs_root, @tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
  end

  test "text selection opens thread immediately", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    render_hook(view, "text_selected", %{
      "text" => "Some content",
      "top" => 200,
      "right" => 500
    })

    html = render(view)
    assert html =~ "Some content"
    assert html =~ "Reply"
  end

  test "closing inline thread clears state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    render_hook(view, "text_selected", %{
      "text" => "Some content",
      "top" => 200,
      "right" => 500
    })

    view |> element(~s{button[phx-click="close_inline_thread"]}) |> render_click()

    html = render(view)
    refute html =~ "Reply"
  end

  test "sending thread message adds it to thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    render_hook(view, "text_selected", %{
      "text" => "Some content",
      "top" => 200,
      "right" => 500
    })

    view
    |> form(~s{form[phx-submit="send_thread_message"]}, %{message: "What about this?"})
    |> render_submit()

    html = render(view)
    assert html =~ "What about this?"
  end

  test "clear selection closes thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    render_hook(view, "text_selected", %{
      "text" => "Some content",
      "top" => 200,
      "right" => 500
    })

    assert render(view) =~ "Reply"

    render_hook(view, "clear_selection", %{})

    refute render(view) =~ "Reply"
  end
end
