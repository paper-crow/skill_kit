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

  test "renders first question immediately on mount", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/setup/#{@conversation_id}")
    assert html =~ "Don&#39;t overthink it"
    refute html =~ "Thinking..."
  end

  test "redirects to editor when docs exist", %{conn: conn} do
    File.write!(Path.join(@tmp_dir, "overview.md"), "# Overview")
    {:error, {:live_redirect, %{to: path}}} = live(conn, "/setup/#{@conversation_id}")
    assert path =~ "overview"
  end

  test "submitting answer shows thinking then next fixed question", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    view |> form("form", %{answer: "track inventory"}) |> render_submit()
    assert render(view) =~ "Thinking..."

    send(view.pid, {:show_fixed_question, 1})
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
    send(view.pid, {:show_fixed_question, 1})

    view |> form("form", %{answer: "Stockpile"}) |> render_submit()

    html = render(view)
    assert html =~ "Thinking..."
    refute html =~ "form"
  end

  test "agent text response renders as question with subtext", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    view |> form("form", %{answer: "track inventory"}) |> render_submit()
    send(view.pid, {:show_fixed_question, 1})

    view |> form("form", %{answer: "Stockpile"}) |> render_submit()
    assert render(view) =~ "Thinking..."

    send(view.pid, %SkillKit.Types.AssistantMessage{
      content:
        "What kinds of items will you track?\n> This helps me understand the data.\ne.g. electronics parts, resistors, ICs",
      tool_calls: []
    })

    html = render(view)
    assert html =~ "This helps me understand the data."
    assert html =~ "electronics parts"
    refute html =~ "Thinking..."
  end

  test "agent text response without hints uses full text as question", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    view |> form("form", %{answer: "track inventory"}) |> render_submit()
    send(view.pid, {:show_fixed_question, 1})

    view |> form("form", %{answer: "Stockpile"}) |> render_submit()

    send(view.pid, %SkillKit.Types.AssistantMessage{
      content: "How many users do you expect?",
      tool_calls: []
    })

    html = render(view)
    assert html =~ "expect?"
    assert html =~ "form"
  end

  test "answering agent question sends message and shows thinking", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    view |> form("form", %{answer: "track inventory"}) |> render_submit()
    send(view.pid, {:show_fixed_question, 1})
    view |> form("form", %{answer: "Stockpile"}) |> render_submit()

    # Agent asks a question via text
    send(view.pid, %SkillKit.Types.AssistantMessage{
      content: "Who uses it?",
      tool_calls: []
    })

    refute render(view) =~ "Thinking..."

    # User answers the agent question — should show thinking state
    view |> form("form", %{answer: "warehouse staff"}) |> render_submit()
    assert render(view) =~ "Thinking..."
  end

  test "doc creation shows generating state then transitions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    # Simulate the tool completing and creating the file
    File.write!(Path.join(@tmp_dir, "overview.md"), "# Stockpile")

    send(view.pid, %SkillKit.Event.ToolCallComplete{
      agent: "onboarding",
      id: "tc_1",
      name: "docs",
      input: %{"path" => "overview.md", "content" => "# Stockpile"}
    })

    # Should show the generating message
    html = render(view)
    assert html =~ "generating your project brief..."

    # After delay, transition starts
    send(view.pid, :start_transition)
    assert render(view) =~ "animate-onboarding-page-exit"

    # After fade-out, navigate to the document
    send(view.pid, :complete_transition)
    {path, _flash} = assert_redirect(view)
    assert path =~ "overview"
  end

  test "shows get started button when docs exist and agent sends summary", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")

    # Create the doc (simulating tool completion)
    File.write!(Path.join(@tmp_dir, "overview.md"), "# Stockpile")

    # Agent sends a summary message after creating the doc
    send(view.pid, %SkillKit.Types.AssistantMessage{
      content: "Your project brief is ready!",
      tool_calls: []
    })

    html = render(view)
    assert html =~ "Your project brief is ready!"
    assert html =~ "Get started"
    refute html =~ "Thinking..."
  end

  test "get_started button triggers transition to editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")
    File.write!(Path.join(@tmp_dir, "overview.md"), "# Stockpile")

    send(view.pid, %SkillKit.Types.AssistantMessage{
      content: "Your project brief is ready!",
      tool_calls: []
    })

    view |> element("button", "Get started") |> render_click()

    html = render(view)
    assert html =~ "animate-onboarding-page-exit"

    send(view.pid, :complete_transition)
    {path, _flash} = assert_redirect(view)
    assert path =~ "overview"
  end

  test "late assistant message is ignored during transition", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")
    File.write!(Path.join(@tmp_dir, "overview.md"), "# Stockpile")

    # Trigger transition
    send(view.pid, %SkillKit.Event.ToolCallComplete{
      agent: "onboarding",
      id: "tc_1",
      name: "docs",
      input: %{"path" => "overview.md"}
    })

    assert render(view) =~ "animate-onboarding-page-exit"

    # Late message arrives — should be ignored
    send(view.pid, %SkillKit.Types.AssistantMessage{
      content: "Here's your brief!",
      tool_calls: []
    })

    # Still transitioning, not showing a new question
    assert render(view) =~ "animate-onboarding-page-exit"
  end

  test "complete_transition navigates to editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/setup/#{@conversation_id}")
    File.write!(Path.join(@tmp_dir, "overview.md"), "# My App")
    send(view.pid, :complete_transition)

    {path, _flash} = assert_redirect(view)
    assert path =~ "overview"
  end
end
