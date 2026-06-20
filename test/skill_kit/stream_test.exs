defmodule SkillKit.StreamTest do
  use ExUnit.Case, async: true

  alias SkillKit.Event.Delta
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Types.AssistantMessage

  describe "stream/2" do
    test "emits non-terminal events in order and ends with the root assistant message" do
      send(self(), %Delta{agent: "neve", text: "a"})
      send(self(), %Delta{agent: "neve", text: "b"})
      send(self(), %AssistantMessage{agent: "neve", content: "ok"})

      assert [
               %Delta{text: "a"},
               %Delta{text: "b"},
               %AssistantMessage{content: "ok"}
             ] = "neve" |> SkillKit.Stream.stream() |> Enum.to_list()
    end

    test "ends with the root error" do
      send(self(), %Delta{agent: "neve", text: "partial"})
      send(self(), %EventError{agent: "neve", reason: :boom})

      assert [
               %Delta{text: "partial"},
               %EventError{reason: :boom}
             ] = "neve" |> SkillKit.Stream.stream() |> Enum.to_list()
    end

    test "passes sub-loop terminal events through without halting" do
      send(self(), %AssistantMessage{agent: "neve/skill:plan", content: "sub"})
      send(self(), %EventError{agent: "neve/skill:plan", reason: :sub_boom})
      send(self(), %Delta{agent: "neve", text: "after"})
      send(self(), %AssistantMessage{agent: "neve", content: "done"})

      events = "neve" |> SkillKit.Stream.stream() |> Enum.to_list()

      assert length(events) == 4
      assert List.last(events) == %AssistantMessage{agent: "neve", content: "done"}
    end

    test "is lazy — Stream.each runs as a side effect, Enum.reduce captures the last event" do
      send(self(), %Delta{agent: "neve", text: "x"})

      send(self(), %ToolCallComplete{
        agent: "neve",
        id: "1",
        name: "bash",
        input: %{"command" => "ls"}
      })

      send(self(), %AssistantMessage{agent: "neve", content: "ok"})

      pid = self()

      final =
        "neve"
        |> SkillKit.Stream.stream()
        |> Stream.each(fn event -> send(pid, {:saw, event}) end)
        |> Enum.reduce(:none, fn event, _ -> event end)

      assert %AssistantMessage{content: "ok"} = final
      assert_received {:saw, %Delta{text: "x"}}
      assert_received {:saw, %ToolCallComplete{name: "bash"}}
      assert_received {:saw, %AssistantMessage{content: "ok"}}
    end

    test "halts on timeout without emitting" do
      assert [] = "neve" |> SkillKit.Stream.stream(timeout: 10) |> Enum.to_list()
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, fn -> SkillKit.Stream.stream("neve", bogus: true) end
    end
  end
end
