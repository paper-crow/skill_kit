defmodule SkillKit.Event.StreamableTest do
  use ExUnit.Case, async: true

  alias Anthropic.Event.ContentBlockDelta
  alias Anthropic.Event.ContentBlockStart
  alias Anthropic.Event.ContentBlockStop
  alias Anthropic.Event.MessageDelta
  alias Anthropic.Event.MessageStart
  alias Anthropic.Event.MessageStop
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.Streamable
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.Event.Usage

  describe "ContentBlockStart" do
    test "text block emits nothing" do
      event = %ContentBlockStart{index: 0, content_block: %{type: :text}}
      assert {[], _acc} = Streamable.stream(event, new_acc())
    end

    test "tool_use block emits ToolCallStart and stores block metadata" do
      event = %ContentBlockStart{
        index: 0,
        content_block: %{type: :tool_use, id: "tc_1", name: "echo"}
      }

      {events, acc} = Streamable.stream(event, new_acc())

      assert [%ToolCallStart{id: "tc_1", name: "echo"}] = events
      assert acc.blocks[0] == %{type: :tool_use, id: "tc_1", name: "echo"}
    end
  end

  describe "ContentBlockDelta" do
    test "text_delta emits Delta" do
      event = %ContentBlockDelta{index: 0, delta: %{type: :text_delta, text: "Hi"}}
      {events, _acc} = Streamable.stream(event, new_acc())

      assert [%Delta{text: "Hi"}] = events
    end

    test "input_json_delta accumulates without emitting" do
      event = %ContentBlockDelta{
        index: 0,
        delta: %{type: :input_json_delta, partial_json: "{\"cmd\":"}
      }

      {events, acc} = Streamable.stream(event, new_acc())

      assert [] = events
      assert acc.partial_json[0] == "{\"cmd\":"
    end

    test "multiple input_json_deltas concatenate" do
      acc = new_acc()

      e1 = %ContentBlockDelta{
        index: 0,
        delta: %{type: :input_json_delta, partial_json: "{\"cmd\":"}
      }

      {[], acc} = Streamable.stream(e1, acc)

      e2 = %ContentBlockDelta{
        index: 0,
        delta: %{type: :input_json_delta, partial_json: "\"ls\"}"}
      }

      {[], acc} = Streamable.stream(e2, acc)

      assert acc.partial_json[0] == "{\"cmd\":\"ls\"}"
    end
  end

  describe "ContentBlockStop" do
    test "tool_use block emits ToolCallComplete with parsed JSON input" do
      acc =
        new_acc()
        |> put_in([:blocks, 0], %{type: :tool_use, id: "tc_1", name: "echo"})
        |> put_in([:partial_json, 0], "{\"cmd\":\"ls\"}")

      event = %ContentBlockStop{index: 0}
      {events, _acc} = Streamable.stream(event, acc)

      assert [%ToolCallComplete{id: "tc_1", name: "echo", input: %{"cmd" => "ls"}}] = events
    end

    test "text block emits nothing" do
      acc = put_in(new_acc(), [:blocks, 0], %{type: :text})
      event = %ContentBlockStop{index: 0}

      assert {[], _acc} = Streamable.stream(event, acc)
    end

    test "tool_use with no partial JSON uses empty object" do
      acc = put_in(new_acc(), [:blocks, 0], %{type: :tool_use, id: "tc_1", name: "noop"})
      event = %ContentBlockStop{index: 0}
      {events, _acc} = Streamable.stream(event, acc)

      assert [%ToolCallComplete{id: "tc_1", name: "noop", input: %{}}] = events
    end
  end

  describe "MessageStart" do
    test "emits Usage with input tokens" do
      event = %MessageStart{id: "msg_1", usage: %{"input_tokens" => 42}}
      {events, _acc} = Streamable.stream(event, new_acc())

      assert [%Usage{input_tokens: 42, output_tokens: 0}] = events
    end

    test "no usage emits nothing" do
      event = %MessageStart{id: "msg_1", usage: nil}
      assert {[], _acc} = Streamable.stream(event, new_acc())
    end

    test "parses cache_creation and cache_read token fields" do
      event = %MessageStart{
        usage: %{
          "input_tokens" => 50,
          "cache_creation_input_tokens" => 200,
          "cache_read_input_tokens" => 800
        }
      }

      assert {[usage], _acc} = Streamable.stream(event, %{})
      assert usage.input_tokens == 50
      assert usage.cache_creation_input_tokens == 200
      assert usage.cache_read_input_tokens == 800
      assert usage.output_tokens == 0
    end
  end

  describe "MessageDelta" do
    test "emits Usage and Done" do
      event = %MessageDelta{stop_reason: :end_turn, usage: %{"output_tokens" => 10}}
      {events, _acc} = Streamable.stream(event, new_acc())

      assert [%Usage{input_tokens: 0, output_tokens: 10}, %Done{stop_reason: :end_turn}] = events
    end

    test "without usage emits only Done" do
      event = %MessageDelta{stop_reason: :tool_use, usage: nil}
      {events, _acc} = Streamable.stream(event, new_acc())

      assert [%Done{stop_reason: :tool_use}] = events
    end
  end

  describe "MessageStop" do
    test "emits nothing" do
      event = %MessageStop{}
      assert {[], _acc} = Streamable.stream(event, new_acc())
    end
  end

  defp new_acc, do: %{blocks: %{}, partial_json: %{}}
end
