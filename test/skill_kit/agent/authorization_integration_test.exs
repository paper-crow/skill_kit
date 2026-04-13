defmodule SkillKit.Agent.AuthorizationIntegrationTest do
  @moduledoc """
  Integration tests verifying that scope-based authorization and hook-based
  denial propagate through the full Server → ToolDispatch → ToolRunner path.

  These tests use the mock LLM and exercise the real Catalog, Hooks, and
  Authorization modules wired together.
  """
  use ExUnit.Case, async: true

  import Mox
  import SkillKit.Test

  alias SkillKit.Hook
  alias SkillKit.Kit
  alias SkillKit.Kit.Memory
  alias SkillKit.Response.Text
  alias SkillKit.Response.ToolCall
  alias SkillKit.Skill
  alias SkillKit.TestScope
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.ToolResult
  alias SkillKit.Types.UserMessage

  setup :verify_on_exit!

  # ---------------------------------------------------------------------------
  # Scope-based skill filtering
  # ---------------------------------------------------------------------------

  describe "scope-based skill filtering" do
    test "nil scope bypasses authorization — all skills visible" do
      {:ok, _pid, ctx} =
        start_server(
          skills: [provider_with_scoped_skill("admin:delete")],
          scope: nil,
          caller: self()
        )

      assert_response(%Text{content: "ok"}, fn _messages, opts ->
        tools = Keyword.get(opts, :tools, [])
        tool_names = Enum.map(tools, & &1.name)
        assert "activate_skill" in tool_names
      end)

      server_pid = find_server(ctx)
      send(server_pid, {:mailbox_flush, [%UserMessage{content: "hi"}]})
      assert_receive %AssistantMessage{}, 2000
    end

    test "empty permissions hides skills that require scope" do
      scope = %TestScope{permissions: []}

      {:ok, _pid, ctx} =
        start_server(
          skills: [provider_with_scoped_skill("admin:delete")],
          scope: scope,
          caller: self()
        )

      assert_response(%Text{content: "ok"}, fn _messages, opts ->
        tools = Keyword.get(opts, :tools, [])
        tool_names = Enum.map(tools, & &1.name)
        refute "activate_skill" in tool_names
      end)

      server_pid = find_server(ctx)
      send(server_pid, {:mailbox_flush, [%UserMessage{content: "hi"}]})
      assert_receive %AssistantMessage{}, 2000
    end

    test "skills requiring scope are visible when agent scope grants it" do
      scope = %TestScope{permissions: ["admin:delete"]}

      {:ok, _pid, ctx} =
        start_server(
          skills: [provider_with_scoped_skill("admin:delete")],
          scope: scope,
          caller: self()
        )

      assert_response(%Text{content: "ok"}, fn _messages, opts ->
        tools = Keyword.get(opts, :tools, [])
        tool_names = Enum.map(tools, & &1.name)
        assert "activate_skill" in tool_names
      end)

      server_pid = find_server(ctx)
      send(server_pid, {:mailbox_flush, [%UserMessage{content: "hi"}]})
      assert_receive %AssistantMessage{}, 2000
    end

    test "skills requiring scope are hidden when agent scope is insufficient" do
      scope = %TestScope{permissions: ["read:only"]}

      {:ok, _pid, ctx} =
        start_server(
          skills: [provider_with_scoped_skill("admin:delete")],
          scope: scope,
          caller: self()
        )

      assert_response(%Text{content: "ok"}, fn _messages, opts ->
        tools = Keyword.get(opts, :tools, [])
        tool_names = Enum.map(tools, & &1.name)
        refute "activate_skill" in tool_names
      end)

      server_pid = find_server(ctx)
      send(server_pid, {:mailbox_flush, [%UserMessage{content: "hi"}]})
      assert_receive %AssistantMessage{}, 2000
    end
  end

  # ---------------------------------------------------------------------------
  # Hook-based tool denial
  # ---------------------------------------------------------------------------

  describe "hook-based tool denial" do
    test "PreToolUse hook denial returns error ToolResult to LLM" do
      {:ok, _pid, ctx} =
        start_server(
          skills: [provider_with_deny_hook()],
          caller: self()
        )

      # First call: LLM returns a tool call
      # Second call: LLM sees the denial error and responds with text
      expect_responses([
        %ToolCall{name: "bash", input: %{"command" => "rm -rf /"}},
        %Text{content: "Tool was denied."}
      ])

      server_pid = find_server(ctx)
      send(server_pid, {:mailbox_flush, [%UserMessage{content: "delete everything"}]})

      # Should receive the denied tool result
      assert_receive %ToolResult{content: "Denied: dangerous command blocked", is_error: true},
                     2000

      # LLM loop continues — second call returns the text response
      assert_receive %AssistantMessage{content: "Tool was denied."}, 2000
    end

    test "PreToolUse hook denial with matcher only blocks matching tools" do
      {:ok, _pid, ctx} =
        start_server(
          skills: [provider_with_selective_deny_hook()],
          caller: self()
        )

      # Tool call to "bash" should be allowed (hook only denies "rm" matcher)
      expect_responses([
        %ToolCall{name: "bash", input: %{"command" => "echo safe"}},
        %Text{content: "Done."}
      ])

      server_pid = find_server(ctx)
      send(server_pid, {:mailbox_flush, [%UserMessage{content: "echo safe"}]})

      # Should NOT receive a denied result — tool executes normally
      assert_receive %ToolResult{content: content}, 2000
      refute content =~ "Denied"

      assert_receive %AssistantMessage{content: "Done."}, 2000
    end

    test "denied tool result includes tool_call_id for LLM context" do
      {:ok, _pid, ctx} =
        start_server(
          skills: [provider_with_deny_hook()],
          caller: self()
        )

      expect_responses([
        %ToolCall{name: "bash", input: %{"command" => "rm -rf /"}},
        %Text{content: "ok"}
      ])

      server_pid = find_server(ctx)
      send(server_pid, {:mailbox_flush, [%UserMessage{content: "do it"}]})

      assert_receive %ToolResult{tool_call_id: id, is_error: true}, 2000
      assert is_binary(id)

      assert_receive %AssistantMessage{}, 2000
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_server(%{registry: registry, agent_name: name}) do
    [{pid, _}] = Registry.lookup(registry, {name, :server})
    pid
  end

  defp provider_with_scoped_skill(required_scope) do
    {:ok, provider} = Memory.start_link([])

    Memory.put(provider, %Skill{
      name: "admin:danger",
      namespace: "admin",
      description: "A dangerous admin skill",
      required_scope: [required_scope]
    })

    {Memory, provider: provider}
  end

  defp provider_with_deny_hook do
    {:ok, provider} = Memory.start_link([])

    hook = %Hook{
      event: :pre_tool_use,
      matcher: nil,
      handler: fn _ctx -> {:deny, "dangerous command blocked"} end
    }

    Memory.put(provider, %Skill{
      name: "tools:shell",
      namespace: "tools",
      description: "Shell tool",
      hooks: [hook]
    })

    Memory.put_kit(provider, %Kit{
      name: "shell",
      metadata: %{tool: SkillKit.Tools.Shell}
    })

    {Memory, provider: provider}
  end

  defp provider_with_selective_deny_hook do
    {:ok, provider} = Memory.start_link([])

    hook = %Hook{
      event: :pre_tool_use,
      matcher: ~r/rm/,
      handler: fn _ctx -> {:deny, "rm commands blocked"} end
    }

    Memory.put(provider, %Skill{
      name: "tools:shell",
      namespace: "tools",
      description: "Shell tool",
      hooks: [hook]
    })

    Memory.put_kit(provider, %Kit{
      name: "shell",
      metadata: %{tool: SkillKit.Tools.Shell}
    })

    {Memory, provider: provider}
  end
end
