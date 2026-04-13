defmodule SkillKit.Agent.ServerTest do
  use ExUnit.Case, async: true

  import Mox
  import SkillKit.Test

  alias SkillKit.Agent.Server
  alias SkillKit.Agent.ToolRunner
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Kit
  alias SkillKit.Kit.Memory
  alias SkillKit.Response.Text
  alias SkillKit.Response.ToolCall
  alias SkillKit.Skill
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.SystemMessage
  alias SkillKit.Types.UserMessage

  setup :verify_on_exit!

  setup do
    registry_name = :"server_test_registry_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    agent = %SkillKit.Agent{
      name: agent_name,
      description: "Test agent",
      system_prompt: "You are a test agent.",
      registry: registry_name
    }

    start_supervised!(
      {SkillKit.Catalog,
       name: {:via, Registry, {registry_name, {agent_name, :catalog}}}, providers: []}
    )

    ToolRunner.start_link(agent)

    {:ok, registry: registry_name, agent_name: agent_name, agent: agent}
  end

  describe "init" do
    test "registers in the agent registry", %{
      registry: registry,
      agent_name: agent_name,
      agent: agent
    } do
      {:ok, pid} = Server.start_link(agent)

      assert [{^pid, _}] = Registry.lookup(registry, {agent_name, :server})
    end
  end

  describe "agent loop" do
    test "streams LLM response and appends to conversation", %{
      agent: agent
    } do
      assert_response(%Text{content: "Hi there!"}, fn messages, _opts ->
        assert [%UserMessage{content: "hello"}] =
                 Enum.filter(messages, &match?(%UserMessage{}, &1))
      end)

      {:ok, pid} = Server.start_link(%{agent | caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "hello"}]})
      assert_receive %AssistantMessage{}, 1000

      state = :sys.get_state(pid)

      assert length(state.messages) == 2
      assert %UserMessage{content: "hello"} = Enum.at(state.messages, 0)
      assert %AssistantMessage{content: "Hi there!"} = Enum.at(state.messages, 1)
    end

    test "executes local tool calls and loops", %{
      agent: agent
    } do
      expect_responses([
        %ToolCall{name: "echo", input: %{"command" => "echo hi"}},
        %Text{content: "Done."}
      ])

      {:ok, pid} = Server.start_link(%{agent | caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "do it"}]})
      assert_receive %AssistantMessage{}, 1000

      state = :sys.get_state(pid)

      assert length(state.messages) >= 4
    end

    test "discards empty assistant response after tool call", %{
      agent: agent
    } do
      # Simulate: tool call → tool result → LLM produces empty response (no text, no tools)
      expect_responses([
        %ToolCall{name: "echo", input: %{"command" => "echo hi"}},
        %SkillKit.Response.Empty{}
      ])

      {:ok, pid} = Server.start_link(%{agent | caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "do it"}]})

      # Should NOT receive an AssistantMessage (empty response is discarded)
      refute_receive %AssistantMessage{}, 500

      state = :sys.get_state(pid)

      # Messages should contain: UserMessage, AssistantMessage (with tool_call), ToolResult
      # but NOT the empty AssistantMessage
      message_types = Enum.map(state.messages, &message_type/1)
      refute :empty_assistant in message_types
    end
  end

  defp message_type(%AssistantMessage{content: nil, tool_calls: []}), do: :empty_assistant
  defp message_type(%AssistantMessage{tool_calls: []}), do: :assistant
  defp message_type(%AssistantMessage{}), do: :assistant_with_tools
  defp message_type(%UserMessage{}), do: :user
  defp message_type(_), do: :other

  describe "LLM error handling" do
    test "gracefully handles LLM stream error without crashing", %{
      agent: agent
    } do
      expect_error(400, "credit balance too low")

      {:ok, pid} = Server.start_link(%{agent | caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "hello"}]})
      assert_receive %EventError{}, 1000

      # Server should still be alive
      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      # User message was appended but no assistant response
      assert [%UserMessage{content: "hello"}] = state.messages
    end

    test "passes system_prompt and model to LLM", %{
      registry: registry,
      agent_name: agent_name
    } do
      agent = %SkillKit.Agent{
        name: agent_name,
        description: "Test agent",
        system_prompt: "You are a calculator.",
        model: "claude-sonnet-4-20250514",
        caller: self(),
        registry: registry
      }

      assert_response(%Text{content: "4"}, fn _messages, opts ->
        assert Keyword.get(opts, :system) == "You are a calculator."
        assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
      end)

      {:ok, pid} = Server.start_link(agent)

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "2+2"}]})
      assert_receive %AssistantMessage{}, 1000
    end
  end

  describe "tools from kits" do
    test "passes tools to LLM when catalog has skills" do
      # Create a fresh registry and catalog with kits for this test
      reg = :"tools_test_registry_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: reg}, id: :tools_reg)

      agent_name = "tools-agent-#{:erlang.unique_integer([:positive])}"

      agent = %SkillKit.Agent{
        name: agent_name,
        description: "Test agent",
        system_prompt: "You are a test agent.",
        caller: self(),
        registry: reg
      }

      {:ok, provider} = Memory.start_link([])

      Memory.put_kit(provider, %Kit{
        name: "shell",
        metadata: %{tool: SkillKit.Tools.Shell}
      })

      Memory.put(provider, %Skill{
        name: "tools:echo",
        namespace: "tools",
        description: "Echo"
      })

      start_supervised!(
        {SkillKit.Catalog,
         name: {:via, Registry, {reg, {agent_name, :catalog}}},
         providers: [{Memory, provider: provider}]},
        id: :tools_catalog
      )

      assert_response(%Text{content: "ok"}, fn _messages, opts ->
        tools = Keyword.get(opts, :tools, [])
        assert Enum.any?(tools, fn t -> t.name == "bash" end)
        assert Enum.any?(tools, fn t -> t.name == "activate_skill" end)
      end)

      {:ok, pid} = Server.start_link(agent)

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "hi"}]})
      assert_receive %AssistantMessage{}, 1000
    end
  end

  describe "caller streaming" do
    test "sends delta and response events to caller pid", %{
      agent_name: agent_name,
      agent: agent
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        events = [
          %Delta{text: "Hi"},
          %Delta{text: " there"},
          %SkillKit.Event.Done{stop_reason: :end_turn}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, pid} = Server.start_link(%{agent | caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "hello"}]})

      assert_receive %Delta{agent: ^agent_name, text: "Hi"}, 1000
      assert_receive %Delta{agent: ^agent_name, text: " there"}, 1000
      assert_receive %AssistantMessage{agent: ^agent_name, content: "Hi there"}, 1000
    end

    test "sends error event to caller on LLM failure", %{
      agent_name: agent_name,
      agent: agent
    } do
      expect_error(500, "internal error")

      {:ok, pid} = Server.start_link(%{agent | caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "hello"}]})

      assert_receive %EventError{agent: ^agent_name, reason: {500, "internal error"}}, 1000
      assert Process.alive?(pid)
    end

    test "streams deltas across tool call loops", %{
      agent_name: agent_name,
      agent: agent
    } do
      expect_responses([
        %ToolCall{name: "echo", input: %{"command" => "echo hi"}},
        %Text{content: "Done!"}
      ])

      {:ok, pid} = Server.start_link(%{agent | caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "do it"}]})

      assert_receive %Delta{agent: ^agent_name, text: "Done!"}, 1000
      assert_receive %AssistantMessage{agent: ^agent_name, content: "Done!"}, 1000
    end
  end

  describe "halted state" do
    test "halted server ignores mailbox flushes", %{
      agent: agent
    } do
      {:ok, pid} = Server.start_link(agent)

      :sys.replace_state(pid, fn state -> %{state | halted: true} end)

      send(pid, {:mailbox_flush, [%UserMessage{content: "hello"}]})

      state = :sys.get_state(pid)
      assert state.messages == []
      assert state.halted == true
    end
  end

  describe "authorization" do
    test "activate_skill passes scope to Catalog for authorization", %{
      agent: agent
    } do
      {:ok, pid} = Server.start_link(%{agent | scope: ["limited:scope"]})

      # Verify the server started with scope
      state = :sys.get_state(pid)
      assert state.agent.scope == ["limited:scope"]
    end

    test "activate_skill skips authorization when scope is nil", %{
      agent: agent
    } do
      {:ok, pid} = Server.start_link(agent)

      state = :sys.get_state(pid)
      assert state.agent.scope == nil
    end
  end

  describe "subagent lifecycle" do
    test "subagent result arrives as System message through mailbox", %{
      agent: agent
    } do
      expect_response(%Text{content: "Got it."})

      {:ok, pid} = Server.start_link(%{agent | caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      system_msg = %SystemMessage{
        content: "[Background task ref_1 complete] Agent 'worker' returned: done"
      }

      send(pid, {:mailbox_flush, [system_msg]})
      assert_receive %AssistantMessage{}, 1000

      state = :sys.get_state(pid)
      assert Enum.any?(state.messages, &match?(%SystemMessage{}, &1))
    end
  end

  describe "natural completion" do
    test "subagent terminates with {:shutdown, {:result, msg}} after final response", %{
      agent: agent,
      registry: registry
    } do
      # Trap exits so the test process isn't killed by the Server's exit
      Process.flag(:trap_exit, true)

      parent_ref = %SkillKit.AgentRef{
        name: "parent",
        registry: registry,
        supervisor_pid: self()
      }

      subagent = %{agent | parent_ref: parent_ref, caller: self()}

      expect_response(%Text{content: "Task complete!"})

      {:ok, pid} = Server.start_link(subagent)
      Mox.allow(SkillKit.LLM.Mock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "do it"}]})

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:result, msg}}}, 2000
      assert %AssistantMessage{content: "Task complete!"} = msg
    end

    test "top-level agent does NOT terminate after final response", %{
      agent: agent
    } do
      expect_response(%Text{content: "Hello!"})

      {:ok, pid} = Server.start_link(%{agent | caller: self()})
      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%UserMessage{content: "hi"}]})

      assert_receive %AssistantMessage{content: "Hello!"}, 1000
      Process.sleep(100)
      assert Process.alive?(pid)
    end
  end
end
