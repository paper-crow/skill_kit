defmodule SkillKit.Agent.SkillActivationTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Agent.Server
  alias SkillKit.Agent.SkillActivation
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.Event.Usage
  alias SkillKit.Kit.Memory
  alias SkillKit.Skill
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.ToolResult
  alias SkillKit.Types.UserMessage

  setup :verify_on_exit!

  # -- fake tool used by the skill under test ------------------------------

  defmodule FakeTool do
    @moduledoc false
    @behaviour SkillKit.Tool

    @impl SkillKit.Tool
    def definition do
      %SkillKit.Tool{
        name: "fake_tool",
        description: "echoes its input with context.mark",
        input_schema: %{"type" => "object", "properties" => %{}}
      }
    end

    @impl SkillKit.Tool
    def execute(%SkillKit.ToolExecution{input: input, context: ctx}) do
      {:ok,
       "mark=#{ctx.mark} agent_name=#{ctx.agent_name} payload=#{Map.get(input, "payload", "")}"}
    end

    @impl SkillKit.Tool
    def resume(_exec, _state, _decision), do: {:error, "resume not supported"}
  end

  # -- setup ---------------------------------------------------------------

  setup do
    registry_name = :"skill_activation_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "parent-#{:erlang.unique_integer([:positive])}"

    agent = %SkAgent{
      name: agent_name,
      description: "test parent",
      system_prompt: "You are the parent.",
      registry: registry_name,
      caller: self()
    }

    start_supervised!(
      {SkillKit.Catalog,
       name: {:via, Registry, {registry_name, {agent_name, :catalog}}}, tools: [], skills: []}
    )

    skill = %Skill{
      name: "fake:do",
      namespace: "fake",
      description: "fake skill",
      body: "Body for fake skill",
      tool: FakeTool,
      metadata: %{mark: "FROM_SKILL_META"}
    }

    state = %Server{agent: agent, messages: [%UserMessage{content: "prior message"}]}

    {:ok, agent: agent, state: state, skill: skill, agent_name: agent_name}
  end

  # -- stream helpers ------------------------------------------------------

  defp tool_call_stream(id, name, input) do
    events = [
      %ToolCallStart{id: id, name: name},
      %ToolCallComplete{id: id, name: name, input: input},
      %Done{stop_reason: :tool_use}
    ]

    {:ok, Stream.map(events, & &1)}
  end

  defp text_stream(text) do
    events = [%Delta{text: text}, %Done{stop_reason: :end_turn}]
    {:ok, Stream.map(events, & &1)}
  end

  # -- tests ---------------------------------------------------------------

  describe "run/4" do
    test "runs a tool call then returns the LLM's final text as the tool result",
         %{state: state, skill: skill} do
      pid = self()

      expect(SkillKit.LLM.Mock, :stream, 2, fn messages, opts ->
        call_count = increment(:calls, 1)
        send(pid, {:llm_call, call_count, messages, opts})

        case call_count do
          1 -> tool_call_stream("tc_1", "fake_tool", %{"payload" => "hello"})
          2 -> text_stream("final summary text")
        end
      end)

      assert %ToolResult{
               tool_call_id: "call_id_1",
               content: "final summary text",
               is_error: false
             } = SkillActivation.run(state, skill, "RENDERED BODY", "call_id_1")

      # Verify the sub-loop's first LLM call received the forked messages
      # and tool definitions including the skill's own tool.
      assert_receive {:llm_call, 1, messages, opts}
      assert messages == [%UserMessage{content: "prior message"}]
      assert Keyword.fetch!(opts, :system) == "You are the parent.\n\nRENDERED BODY"
      tool_defs = Keyword.fetch!(opts, :tools)
      assert Enum.any?(tool_defs, &(&1.name == "fake_tool"))

      # Second LLM call should see the assistant message + tool result
      # appended, proving the sub-loop threaded them through.
      assert_receive {:llm_call, 2, messages, _opts}
      assert Enum.any?(messages, &match?(%AssistantMessage{tool_calls: [_ | _]}, &1))
      assert Enum.any?(messages, &match?(%ToolResult{tool_call_id: "tc_1"}, &1))
    end

    test "does not mutate the parent's messages list", %{state: state, skill: skill} do
      expect(SkillKit.LLM.Mock, :stream, fn _msgs, _opts -> text_stream("hi") end)

      %ToolResult{} = SkillActivation.run(state, skill, "body", "id")

      assert state.messages == [%UserMessage{content: "prior message"}]
    end

    test "strips the parent's trailing assistant-with-tool_calls before sub-loop's LLM call",
         %{agent: agent, skill: skill} do
      # Parent messages end with an AssistantMessage whose tool_use is the
      # very `activate_skill` call that triggered this sub-loop. Passing it
      # to Anthropic would leave a dangling tool_use (no matching
      # tool_result yet).
      pending = %AssistantMessage{
        content: "I'll handle this",
        tool_calls: [
          %SkillKit.Types.ToolCall{id: "parent_tc", name: "activate_skill", input: %{}}
        ]
      }

      state = %Server{
        agent: agent,
        messages: [%UserMessage{content: "do it"}, pending]
      }

      pid = self()

      expect(SkillKit.LLM.Mock, :stream, fn messages, _opts ->
        send(pid, {:sub_messages, messages})
        text_stream("ok")
      end)

      SkillActivation.run(state, skill, "body", "id")

      assert_receive {:sub_messages, messages}
      assert messages == [%UserMessage{content: "do it"}]
    end

    test "forwards events tagged with a synthetic sub-agent name",
         %{state: state, skill: skill, agent_name: agent_name} do
      expect(SkillKit.LLM.Mock, :stream, fn _msgs, _opts -> text_stream("hello from sub") end)

      SkillActivation.run(state, skill, "body", "id")

      sub_name = "#{agent_name}/skill:fake:do"
      assert_receive %Delta{agent: ^sub_name, text: "hello from sub"}
    end

    test "forwards Usage events from the sub-loop to the caller, tagged with sub-agent name",
         %{state: state, skill: skill, agent_name: agent_name} do
      expect(SkillKit.LLM.Mock, :stream, fn _msgs, _opts ->
        events = [
          %Delta{text: "x"},
          %Usage{input_tokens: 11, output_tokens: 22},
          %Done{stop_reason: :end_turn}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      SkillActivation.run(state, skill, "body", "id")

      sub_name = "#{agent_name}/skill:fake:do"
      assert_receive %Usage{agent: ^sub_name, input_tokens: 11, output_tokens: 22}
    end

    test "passes skill metadata through to the tool context", %{state: state, skill: skill} do
      expect(SkillKit.LLM.Mock, :stream, 2, fn _msgs, _opts ->
        call_count = increment(:meta_calls, 1)

        case call_count do
          1 -> tool_call_stream("tc_meta", "fake_tool", %{"payload" => "P"})
          2 -> text_stream("done")
        end
      end)

      assert %ToolResult{content: "done"} = SkillActivation.run(state, skill, "body", "id")

      # The sub-loop forwarded the tool's ToolResult to the caller; its
      # content encodes ctx.mark (from skill.metadata) and ctx.agent_name.
      assert_receive %ToolResult{tool_call_id: "tc_meta", content: content}, 1000
      assert content =~ "mark=FROM_SKILL_META"
      assert content =~ "agent_name=#{state.agent.name}"
    end

    test "returns an error ToolResult when the LLM stream errors",
         %{state: state, skill: skill} do
      expect(SkillKit.LLM.Mock, :stream, fn _msgs, _opts -> {:error, {503, "down"}} end)

      assert %ToolResult{
               tool_call_id: "id",
               is_error: false,
               content: content
             } = SkillActivation.run(state, skill, "body", "id")

      assert content =~ "Skill activation error"
    end

    test "returns a denial ToolResult when a pre-hook denies the activation",
         %{state: _state, skill: skill, agent: agent} do
      # Rebuild the catalog with a deny hook attached to the skill.
      deny_skill = %{
        skill
        | hooks: [
            %SkillKit.Hook{
              event: :pre_skill_activation,
              matcher: nil,
              handler: fn _ctx -> {:deny, "nope"} end
            }
          ]
      }

      reg = :"deny_registry_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: reg}, id: :deny_reg)

      name = "deny-agent-#{:erlang.unique_integer([:positive])}"

      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, deny_skill)

      start_supervised!(
        {SkillKit.Catalog,
         name: {:via, Registry, {reg, {name, :catalog}}},
         tools: [],
         skills: [{Memory, provider: provider}]},
        id: :deny_catalog
      )

      deny_agent = %{agent | name: name, registry: reg, caller: self()}
      deny_state = %Server{agent: deny_agent, messages: []}

      assert %ToolResult{tool_call_id: "id", is_error: true, content: "Denied: nope"} =
               SkillActivation.run(deny_state, deny_skill, "body", "id")
    end
  end

  # -- helpers -------------------------------------------------------------

  defp increment(key, delta) do
    count = Process.get({__MODULE__, key}, 0) + delta
    Process.put({__MODULE__, key}, count)
    count
  end
end
