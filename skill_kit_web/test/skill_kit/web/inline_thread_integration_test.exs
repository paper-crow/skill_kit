defmodule SkillKit.Web.InlineThreadIntegrationTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  @tmp_dir Path.expand("../../tmp/inline_thread_test", __DIR__)

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
    assert html =~ "Reply"
  end

  test "dismiss saves thread as suspended when draft exists", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    render_hook(view, "text_selected", %{
      "text" => "Some content",
      "top" => 200,
      "right" => 500
    })

    assert render(view) =~ "Reply"

    # Simulate typing a draft
    render_hook(view, "update_thread_draft", %{"message" => "half typed"})

    # Dismiss the thread (click away)
    render_hook(view, "dismiss_inline_thread", %{})

    refute render(view) =~ "Reply"

    # Re-select same text — should restore the draft
    render_hook(view, "text_selected", %{
      "text" => "Some content",
      "top" => 200,
      "right" => 500
    })

    html = render(view)
    assert html =~ "Reply"
    assert html =~ "half typed"
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

  test "esc closes thread and clears draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    render_hook(view, "text_selected", %{
      "text" => "Some content",
      "top" => 200,
      "right" => 500
    })

    assert render(view) =~ "Reply"

    # close_inline_thread clears draft and suspended
    render_hook(view, "close_inline_thread", %{})

    refute render(view) =~ "Reply"
  end
end
