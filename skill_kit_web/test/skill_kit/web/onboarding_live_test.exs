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

  test "shows thinking state after last fixed question", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    view |> form("form", %{answer: "track inventory"}) |> render_submit()
    view |> form("form", %{answer: "Stockpile"}) |> render_submit()

    html = render(view)
    assert html =~ "Thinking..."
    refute html =~ "form"
  end

  test "agent question replaces thinking state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    view |> form("form", %{answer: "track inventory"}) |> render_submit()
    view |> form("form", %{answer: "Stockpile"}) |> render_submit()
    assert render(view) =~ "Thinking..."

    # Simulate agent sending a follow-up question
    send(view.pid, %SkillKit.Types.AssistantMessage{
      content:
        "QUESTION: What kinds of items will you track?\nSUBTEXT: This helps me understand the data.",
      tool_calls: []
    })

    html = render(view)
    # Words are split into animated spans, so check subtext (rendered contiguously)
    assert html =~ "This helps me understand the data."
    refute html =~ "Thinking..."
  end

  test "agent question without markers uses full text", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    view |> form("form", %{answer: "track inventory"}) |> render_submit()
    view |> form("form", %{answer: "Stockpile"}) |> render_submit()

    send(view.pid, %SkillKit.Types.AssistantMessage{
      content: "How many users do you expect?",
      tool_calls: []
    })

    # Words are in animated spans — check for a unique word and the form
    html = render(view)
    assert html =~ "expect?"
    assert html =~ "form"
  end

  test "doc creation shows creating state then transitions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    # Simulate agent deciding to create the brief
    send(view.pid, %SkillKit.Types.AssistantMessage{
      content: "Great, I have enough to create your project brief.",
      tool_calls: [
        %SkillKit.Types.ToolCall{
          id: "tc_1",
          name: "docs",
          input: %{"path" => "overview.md", "content" => "# Stockpile"}
        }
      ]
    })

    html = render(view)
    assert html =~ "Creating your project brief..."

    # Simulate the tool completing and creating the file
    File.write!(Path.join(@tmp_dir, "overview.md"), "# Stockpile")

    send(view.pid, %SkillKit.Event.ToolCallComplete{
      agent: "onboarding",
      id: "tc_1",
      name: "docs",
      input: %{"path" => "overview.md", "content" => "# Stockpile"}
    })

    # Should trigger the transition
    html = render(view)
    assert html =~ "animate-onboarding-page-exit"

    # After the timer fires, should navigate to the document
    send(view.pid, :complete_transition)
    {path, _flash} = assert_redirect(view)
    assert path =~ "overview"
  end

  test "complete_transition navigates to editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")
    File.write!(Path.join(@tmp_dir, "overview.md"), "# My App")
    send(view.pid, :complete_transition)

    {path, _flash} = assert_redirect(view)
    assert path =~ "overview"
  end
end
