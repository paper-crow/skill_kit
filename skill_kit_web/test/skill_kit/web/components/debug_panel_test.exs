defmodule SkillKit.Web.Components.DebugPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SkillKit.Web.Components.DebugPanel

  test "renders empty state when no events" do
    html =
      render_component(&DebugPanel.debug_panel/1,
        events: [],
        event_count: 0,
        paused: false,
        open: true
      )

    assert html =~ "Waiting for telemetry events"
    assert html =~ "0 events"
  end

  test "renders events" do
    events = [
      %{
        timestamp: "12:34:56.789",
        label: "TOOL_USE:START",
        category: :tool,
        duration: nil,
        detail: "tool=docs:read"
      }
    ]

    html =
      render_component(&DebugPanel.debug_panel/1,
        events: events,
        event_count: 1,
        paused: false,
        open: true
      )

    assert html =~ "TOOL_USE:START"
    assert html =~ "tool=docs:read"
    assert html =~ "1 events"
  end

  test "renders duration when present" do
    events = [
      %{
        timestamp: "12:34:56.789",
        label: "LLM_REQUEST:STOP",
        category: :llm,
        duration: "150ms",
        detail: "model=claude-sonnet-4-20250514"
      }
    ]

    html =
      render_component(&DebugPanel.debug_panel/1,
        events: events,
        event_count: 1,
        paused: false,
        open: true
      )

    assert html =~ "150ms"
    assert html =~ "model=claude-sonnet-4-20250514"
  end

  test "hidden when not open" do
    html =
      render_component(&DebugPanel.debug_panel/1,
        events: [],
        event_count: 0,
        paused: false,
        open: false
      )

    assert html =~ "hidden"
  end

  test "shows paused indicator" do
    html =
      render_component(&DebugPanel.debug_panel/1,
        events: [],
        event_count: 0,
        paused: true,
        open: true
      )

    assert html =~ "Resume"
    assert html =~ "Paused"
  end
end
