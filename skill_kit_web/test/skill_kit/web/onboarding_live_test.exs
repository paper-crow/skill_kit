defmodule SkillKit.Web.OnboardingLiveTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  @tmp_dir Path.expand("../../tmp/onboarding_live_test", __DIR__)
  @conversation_id "test-conversation-abc"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    Application.put_env(:skill_kit_web, :docs_root, @tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
  end

  test "renders first question on mount", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/setup/#{@conversation_id}")
    assert html =~ "Don&#39;t overthink it"
  end

  test "redirects to editor when docs exist", %{conn: conn} do
    File.write!(Path.join(@tmp_dir, "overview.md"), "# Overview")
    {:error, {:live_redirect, %{to: path}}} = live(conn, "/setup/#{@conversation_id}")
    assert path =~ "overview"
  end

  test "submitting answer advances to next fixed question", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")
    assert render(view) =~ "Don&#39;t overthink it"

    view |> form("form", %{answer: "track inventory"}) |> render_submit()
    assert render(view) =~ "You can always change this later"
  end

  test "empty answer does not advance", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")
    view |> form("form", %{answer: ""}) |> render_submit()
    assert render(view) =~ "Don&#39;t overthink it"
  end

  test "complete_transition navigates to editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")
    File.write!(Path.join(@tmp_dir, "overview.md"), "# My App")
    send(view.pid, :complete_transition)

    {path, _flash} = assert_redirect(view)
    assert path =~ "overview"
  end
end
