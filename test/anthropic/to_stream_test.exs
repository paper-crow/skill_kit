defmodule Anthropic.ToStreamTest do
  use ExUnit.Case, async: true

  alias Anthropic.Event
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.Streamable
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Response.Error
  alias SkillKit.Response.Text
  alias SkillKit.Response.ToolCall

  describe "to_stream/1" do
    test "Text returns stream that yields Delta and Done events" do
      {:ok, stream} = Anthropic.Test.to_stream(%Text{content: "Hello"})
      sk_events = convert_via_streamable(Enum.to_list(stream))

      assert Enum.any?(sk_events, &match?(%Delta{text: "Hello"}, &1))
      assert Enum.any?(sk_events, &match?(%Done{stop_reason: :end_turn}, &1))
    end

    test "ToolCall returns stream that yields ToolCallComplete and Done events" do
      {:ok, stream} = Anthropic.Test.to_stream(%ToolCall{name: "bash", input: %{"cmd" => "ls"}})
      sk_events = convert_via_streamable(Enum.to_list(stream))

      tc = Enum.find(sk_events, &match?(%ToolCallComplete{}, &1))
      assert tc.name == "bash"
      assert tc.input == %{"cmd" => "ls"}

      assert Enum.any?(sk_events, &match?(%Done{stop_reason: :tool_use}, &1))
    end

    test "Error returns error tuple" do
      assert {:error, {500, "boom"}} =
               Anthropic.Test.to_stream(%Error{status: 500, message: "boom"})
    end
  end

  defp convert_via_streamable(raw_events) do
    raw_events
    |> Enum.map(&Event.parse/1)
    |> Enum.reject(&(&1 == :skip))
    |> Enum.flat_map_reduce(%{blocks: %{}, partial_json: %{}}, fn event, acc ->
      Streamable.to_events(event, acc)
    end)
    |> elem(0)
  end
end
