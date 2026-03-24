defmodule Anthropic.TestTest do
  use ExUnit.Case, async: true

  alias Anthropic.Event
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.Streamable
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart

  describe "text_events/1" do
    test "produces events that convert to Delta and Done via Streamable" do
      raw_events = Anthropic.Test.text_events("Hello world")
      sk_events = convert_via_streamable(raw_events)

      assert Enum.any?(sk_events, &match?(%Delta{text: "Hello world"}, &1))
      assert Enum.any?(sk_events, &match?(%Done{stop_reason: :end_turn}, &1))
    end

    test "returns a list of 6 SSE event maps" do
      events = Anthropic.Test.text_events("Hi")

      assert length(events) == 6
      assert %{"type" => "message_start"} = List.first(events)
      assert %{"type" => "message_stop"} = List.last(events)
    end
  end

  describe "tool_call_events/2" do
    test "produces events that convert to ToolCallStart, ToolCallComplete, and Done" do
      raw_events = Anthropic.Test.tool_call_events("echo", %{"command" => "echo hi"})
      sk_events = convert_via_streamable(raw_events)

      assert Enum.any?(sk_events, &match?(%ToolCallStart{name: "echo"}, &1))

      tc = Enum.find(sk_events, &match?(%ToolCallComplete{}, &1))
      assert tc.name == "echo"
      assert tc.input == %{"command" => "echo hi"}

      assert Enum.any?(sk_events, &match?(%Done{stop_reason: :tool_use}, &1))
    end

    test "returns a list of 6 SSE event maps" do
      events = Anthropic.Test.tool_call_events("bash", %{"cmd" => "ls"})

      assert length(events) == 6
      assert %{"type" => "message_start"} = List.first(events)
      assert %{"type" => "message_stop"} = List.last(events)
    end
  end

  # Converts raw Anthropic SSE event maps through the full pipeline:
  # parse -> Streamable.to_events -> flatten
  defp convert_via_streamable(raw_events) do
    raw_events
    |> Enum.map(&Event.parse/1)
    |> Enum.reject(&(&1 == :skip))
    |> Enum.flat_map_reduce(%{blocks: %{}, partial_json: %{}}, fn event, acc ->
      {events, acc} = Streamable.to_events(event, acc)
      {events, acc}
    end)
    |> elem(0)
  end
end
