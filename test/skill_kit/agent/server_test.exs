defmodule SkillKit.Agent.ServerTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent.Definition
  alias SkillKit.Agent.Mailbox
  alias SkillKit.Agent.Server
  alias SkillKit.LLM.Message

  setup :verify_on_exit!

  setup do
    registry_name = :"server_test_registry_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    definition = %Definition{
      name: agent_name,
      description: "Test agent",
      system_prompt: "You are a test agent.",
      path: "/tmp/test",
      workspace: "/tmp/test"
    }

    {:ok, registry: registry_name, agent_name: agent_name, definition: definition}
  end

  describe "init" do
    test "registers in the agent registry", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, pid} = Server.start_link({agent_name, definition, 0, nil, nil, registry})

      assert [{^pid, _}] = Registry.lookup(registry, {agent_name, :server})
    end
  end

  describe "agent loop" do
    test "streams LLM response and appends to conversation", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn messages, _opts ->
        assert [%Message.User{content: "hello"}] =
                 Enum.filter(messages, &match?(%Message.User{}, &1))

        events = [
          %{
            "type" => "message_start",
            "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
          },
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hi there!"}
          },
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "hello"}]})
      Process.sleep(50)

      state = :sys.get_state(pid)

      assert length(state.messages) == 2
      assert %Message.User{content: "hello"} = Enum.at(state.messages, 0)
      assert %Message.Assistant{content: "Hi there!"} = Enum.at(state.messages, 1)
    end

    test "executes local tool calls and loops", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      call_count = :counters.new(1, [:atomics])

      expect(SkillKit.LLM.Mock, :stream, 2, fn _messages, _opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        events =
          if count == 1 do
            [
              %{
                "type" => "message_start",
                "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
              },
              %{
                "type" => "content_block_start",
                "index" => 0,
                "content_block" => %{
                  "type" => "tool_use",
                  "id" => "tc_1",
                  "name" => "echo",
                  "input" => %{}
                }
              },
              %{
                "type" => "content_block_delta",
                "index" => 0,
                "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"command\": \"echo hi\"}"}
              },
              %{"type" => "content_block_stop", "index" => 0},
              %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
              %{"type" => "message_stop"}
            ]
          else
            [
              %{
                "type" => "message_start",
                "message" => %{"id" => "msg_2", "role" => "assistant", "content" => []}
              },
              %{
                "type" => "content_block_start",
                "index" => 0,
                "content_block" => %{"type" => "text", "text" => ""}
              },
              %{
                "type" => "content_block_delta",
                "index" => 0,
                "delta" => %{"type" => "text_delta", "text" => "Done."}
              },
              %{"type" => "content_block_stop", "index" => 0},
              %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
              %{"type" => "message_stop"}
            ]
          end

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "do it"}]})
      Process.sleep(100)

      state = :sys.get_state(pid)

      assert length(state.messages) >= 4
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "LLM error handling" do
    test "gracefully handles LLM stream error without crashing", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        {:error, {400, "credit balance too low"}}
      end)

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "hello"}]})
      Process.sleep(50)

      # Server should still be alive
      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      # User message was appended but no assistant response
      assert [%Message.User{content: "hello"}] = state.messages
    end

    test "passes system_prompt and model to LLM", %{
      registry: registry,
      agent_name: agent_name
    } do
      definition = %Definition{
        name: agent_name,
        description: "Test agent",
        system_prompt: "You are a calculator.",
        path: "/tmp/test",
        workspace: "/tmp/test",
        model: "claude-sonnet-4-20250514"
      }

      expect(SkillKit.LLM.Mock, :stream, fn _messages, opts ->
        assert Keyword.get(opts, :system) == "You are a calculator."
        assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"

        events = [
          %{
            "type" => "message_start",
            "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
          },
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "4"}
          },
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "2+2"}]})
      Process.sleep(50)
    end
  end

  describe "tools from kits" do
    test "passes tools to LLM when kits have skills", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, opts ->
        tools = Keyword.get(opts, :tools, [])
        assert Enum.any?(tools, fn t -> t.name == "bash" end)
        assert Enum.any?(tools, fn t -> t.name == "activate_skill" end)

        events = [
          %{
            "type" => "message_start",
            "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
          },
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "ok"}
          },
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      kits = [
        %SkillKit.Kit{
          name: "test",
          skills: [%SkillKit.Skill{name: "tools:echo", namespace: "tools", description: "Echo"}]
        }
      ]

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry, kits: kits})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "hi"}]})
      Process.sleep(50)
    end
  end

  describe "caller streaming" do
    test "sends delta and response events to caller pid", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        events = [
          %{
            "type" => "message_start",
            "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
          },
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hi"}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => " there"}
          },
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry, caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "hello"}]})

      assert_receive {:skill_kit, ^agent_name, {:delta, "Hi"}}, 1000
      assert_receive {:skill_kit, ^agent_name, {:delta, " there"}}, 1000
      assert_receive {:skill_kit, ^agent_name, {:response, "Hi there"}}, 1000
    end

    test "sends error event to caller on LLM failure", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        {:error, {500, "internal error"}}
      end)

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry, caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "hello"}]})

      assert_receive {:skill_kit, ^agent_name, {:error, {500, "internal error"}}}, 1000
      assert Process.alive?(pid)
    end

    test "streams deltas across tool call loops", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      call_count = :counters.new(1, [:atomics])

      expect(SkillKit.LLM.Mock, :stream, 2, fn _messages, _opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        events =
          if count == 1 do
            [
              %{
                "type" => "message_start",
                "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
              },
              %{
                "type" => "content_block_start",
                "index" => 0,
                "content_block" => %{
                  "type" => "tool_use",
                  "id" => "tc_1",
                  "name" => "echo",
                  "input" => %{}
                }
              },
              %{
                "type" => "content_block_delta",
                "index" => 0,
                "delta" => %{
                  "type" => "input_json_delta",
                  "partial_json" => "{\"command\":\"echo hi\"}"
                }
              },
              %{"type" => "content_block_stop", "index" => 0},
              %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
              %{"type" => "message_stop"}
            ]
          else
            [
              %{
                "type" => "message_start",
                "message" => %{"id" => "msg_2", "role" => "assistant", "content" => []}
              },
              %{
                "type" => "content_block_start",
                "index" => 0,
                "content_block" => %{"type" => "text", "text" => ""}
              },
              %{
                "type" => "content_block_delta",
                "index" => 0,
                "delta" => %{"type" => "text_delta", "text" => "Done!"}
              },
              %{"type" => "content_block_stop", "index" => 0},
              %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
              %{"type" => "message_stop"}
            ]
          end

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry, caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "do it"}]})

      assert_receive {:skill_kit, ^agent_name, {:delta, "Done!"}}, 1000
      assert_receive {:skill_kit, ^agent_name, {:response, "Done!"}}, 1000
    end
  end

  describe "halted state" do
    test "halted server ignores mailbox flushes", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry})

      :sys.replace_state(pid, fn state -> %{state | halted: true} end)

      send(pid, {:mailbox_flush, [%Message.User{content: "hello"}]})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.messages == []
      assert state.halted == true
    end
  end

  describe "builtins" do
    test "report_result sends to parent and halts server", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      # Set up a parent registry and register ourselves as the parent
      parent_registry = :"parent_reg_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: parent_registry})
      parent_name = "test-parent"
      Registry.register(parent_registry, {parent_name, :server}, [])

      # Mock: LLM returns a report_result tool call
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        events = [
          %{
            "type" => "message_start",
            "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
          },
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "tc_1",
              "name" => "report_result",
              "input" => %{}
            }
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{
              "type" => "input_json_delta",
              "partial_json" => "{\"result\": \"All good\"}"
            }
          },
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
          %{"type" => "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, pid} =
        Server.start_link(
          {agent_name, definition, 1, parent_name, nil, registry,
           parent_registry: parent_registry}
        )

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "report your findings"}]})

      # Parent (us) should receive the result
      assert_receive {:subagent_result, ^pid, "All good"}, 2000

      # Server should be halted
      Process.sleep(50)
      state = :sys.get_state(pid)
      assert state.halted == true
    end

    test "report_result with missing parent emits telemetry and halts", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      parent_registry = :"orphan_reg_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: parent_registry})

      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        events = [
          %{
            "type" => "message_start",
            "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
          },
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "tc_1",
              "name" => "report_result",
              "input" => %{}
            }
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{
              "type" => "input_json_delta",
              "partial_json" => "{\"result\": \"orphaned\"}"
            }
          },
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
          %{"type" => "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, pid} =
        Server.start_link(
          {agent_name, definition, 1, "gone-parent", nil, registry,
           parent_registry: parent_registry}
        )

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "report"}]})
      Process.sleep(100)

      # Should not crash, should be halted
      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      assert state.halted == true
    end
  end

  describe "authorization" do
    test "activate_skill passes scope to Catalog for authorization", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, ["limited:scope"], registry})

      # Verify the server started with scope
      state = :sys.get_state(pid)
      assert state.scope == ["limited:scope"]
    end

    test "activate_skill skips authorization when scope is nil", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry})

      state = :sys.get_state(pid)
      assert state.scope == nil
    end
  end

  describe "subagent lifecycle" do
    test "subagent result arrives as System message through mailbox", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        events = [
          %{
            "type" => "message_start",
            "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
          },
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Got it."}
          },
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      system_msg = %Message.System{
        content: "[Background task ref_1 complete] Agent 'worker' returned: done"
      }

      send(pid, {:mailbox_flush, [system_msg]})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert Enum.any?(state.messages, &match?(%Message.System{}, &1))
    end
  end

  describe "subagent result handling" do
    test "builds rich resume message with parent_intent and task", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn messages, _opts ->
        last = List.last(messages)
        assert %Message.System{content: content} = last
        assert content =~ "Subagent Complete"
        assert content =~ "review the code"
        assert content =~ "check lib/skill_kit.ex"
        assert content =~ "Found 2 issues"

        events = [
          %{
            "type" => "message_start",
            "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
          },
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Fixing now."}
          },
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      mailbox_config = %{max_messages: 1, flush_interval: 50}
      {:ok, _mailbox_pid} = Mailbox.start_link({agent_name, mailbox_config, registry})

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, nil, registry, caller: self()})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      fake_subagent_pid = spawn(fn -> Process.sleep(:infinity) end)
      monitor_ref = Process.monitor(fake_subagent_pid)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | subagents:
              Map.put(state.subagents, fake_subagent_pid, %{
                name: "code-reviewer",
                task: "check lib/skill_kit.ex",
                monitor_ref: monitor_ref,
                parent_intent: "I'll review the code",
                agent_ref: nil
              })
        }
      end)

      send(pid, {:subagent_result, fake_subagent_pid, "Found 2 issues"})

      assert_receive {:skill_kit, ^agent_name, {:delta, "Fixing now."}}, 2000
      assert_receive {:skill_kit, ^agent_name, {:response, "Fixing now."}}, 2000
    end
  end
end
