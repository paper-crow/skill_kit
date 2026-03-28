defmodule SkillKit.Web.DebugLiveTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders debug view with empty event log", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/debug")
    assert html =~ "Telemetry Debug"
    assert html =~ "Waiting for telemetry events"
    assert html =~ "0 events"
  end

  test "receives telemetry events and displays them", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/debug")

    :telemetry.execute(
      [:skill_kit, :tool_use, :start],
      %{system_time: System.system_time()},
      %{tool_name: "docs:read"}
    )

    # Give the LiveView time to process the message
    html = render(view)
    assert html =~ "TOOL_USE:START"
    assert html =~ "tool=docs:read"
    assert html =~ "1 events"
  end

  test "pausing stops new events from appearing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/debug")

    view |> element("button", "Pause") |> render_click()
    assert render(view) =~ "Resume"

    :telemetry.execute(
      [:skill_kit, :tool_use, :start],
      %{system_time: System.system_time()},
      %{tool_name: "docs:read"}
    )

    html = render(view)
    assert html =~ "0 events"
  end

  test "clear button removes all events", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/debug")

    :telemetry.execute(
      [:skill_kit, :tool_use, :start],
      %{system_time: System.system_time()},
      %{tool_name: "docs:read"}
    )

    assert render(view) =~ "1 events"

    view |> element("button", "Clear") |> render_click()
    html = render(view)
    assert html =~ "0 events"
    assert html =~ "Waiting for telemetry events"
  end

  test "displays duration for stop events", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/debug")

    :telemetry.execute(
      [:skill_kit, :llm_request, :stop],
      %{duration: System.convert_time_unit(150, :millisecond, :native)},
      %{model: "claude-sonnet-4-20250514"}
    )

    html = render(view)
    assert html =~ "LLM_REQUEST:STOP"
    assert html =~ "150ms"
    assert html =~ "model=claude-sonnet-4-20250514"
  end
end
