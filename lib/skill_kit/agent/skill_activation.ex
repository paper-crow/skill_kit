defmodule SkillKit.Agent.SkillActivation do
  @moduledoc """
  Runs an activated skill as a forked sub-conversation in the parent
  agent's process.

  A skill activation is not a new agent and does not spawn a new
  supervision tree. Instead, it runs a synchronous LLM loop in-process
  using a forked copy of the parent's messages and an expanded tool
  list.

  The sub-loop:

    * Uses the parent's system prompt with the rendered skill body
      appended.
    * Inherits the parent's `:tools` and adds the skill's underlying
      tool module (deduplicated by module).
    * Does NOT expose `activate_skill` or subagent-delegation tools —
      nested skill activation is not supported.
    * Loops `LLM.stream/2` plus in-process tool execution until the
      LLM returns a final assistant message with no tool calls.
    * Returns that final text as the `activate_skill` tool's result.

  Events streamed by the sub-loop (`%Delta{}`, tool call events, tool
  results, token usage) are forwarded to the parent's `caller` pid
  tagged with a synthetic agent name `"<parent>/skill:<skill_name>"`,
  so chat printers that match by agent-name prefix surface them
  alongside the parent's own events.

  Wrapped in `Hooks.call(:skill_activation)` so
  `[:skill_kit, :skill_activation, :start/:stop]` telemetry fires and
  `:pre_skill_activation` / `:post_skill_activation` hooks can observe
  or deny the activation.

  ## Implementation

  The LLM + tool-dispatch loop is the shared `SkillKit.Agent.SubLoop`
  primitive. This module's responsibility is preparing the
  skill-specific scope (tool list with skill's tool appended, fork the
  parent messages to drop the trailing `activate_skill` tool use,
  compose the skill-prefixed sub-agent name) and wrapping the run in
  the `:skill_activation` hook.
  """

  alias SkillKit.Agent.Server
  alias SkillKit.Agent.SubLoop
  alias SkillKit.Catalog
  alias SkillKit.Hooks
  alias SkillKit.Skill
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.ToolResult

  @spec run(Server.t(), Skill.t(), String.t(), String.t()) :: ToolResult.t()
  def run(%Server{} = parent_state, %Skill{} = skill, body, tool_call_id)
      when is_binary(body) and is_binary(tool_call_id) do
    hook_context = %{skill: skill, agent_name: parent_state.agent.name}

    outcome =
      Hooks.call(parent_state.agent, :skill_activation, hook_context, fn ->
        text = SubLoop.run(parent_state, build_config(parent_state, skill, body))
        {text, Map.put(hook_context, :result, text)}
      end)

    to_tool_result(outcome, tool_call_id)
  end

  @doc """
  Resolves the skill named in `input["name"]`, renders its body in the
  parent's scope, and runs it as a sub-loop. Used by both the parent
  agent's tool dispatcher and event sub-loops that opt into
  `activate_skill` exposure.

  Returns a `%ToolResult{}` (always — errors are formatted as error
  results, not raised).
  """
  @spec dispatch(Server.t(), String.t(), map()) :: ToolResult.t()
  def dispatch(%Server{} = parent_state, tool_call_id, input)
      when is_binary(tool_call_id) and is_map(input) do
    skill_name = Map.get(input, "name", "")

    case resolve_and_render(parent_state, skill_name) do
      {:ok, skill, body} -> run(parent_state, skill, body, tool_call_id)
      {:error, reason} -> error_result(tool_call_id, reason)
    end
  end

  defp resolve_and_render(state, skill_name) do
    with {:ok, skill} <- Catalog.get_skill(state.agent, skill_name),
         {:ok, body} <- render(skill, state) do
      {:ok, skill, body}
    end
  end

  defp render(skill, state) do
    scope_context = %{agent: state.agent.name, skill: skill.name}
    Skill.render(skill, %{}, state.agent.scope, scope_context)
  end

  defp error_result(id, reason) do
    %ToolResult{
      tool_call_id: id,
      name: "activate_skill",
      content: "Skill activation failed: #{inspect(reason)}",
      is_error: true
    }
  end

  # -- sub-loop scope ------------------------------------------------------

  defp build_config(parent_state, skill, body) do
    %{
      system_append: body,
      initial_messages: fork_messages(parent_state.messages),
      sub_tools: build_sub_tools(parent_state, skill),
      sub_name: "#{parent_state.agent.name}/skill:#{skill.name}",
      error_prefix: "Skill activation error"
    }
  end

  # The parent's trailing assistant message carries the `activate_skill`
  # tool_use that triggered this sub-loop. Including it in the sub-loop's
  # request would leave a dangling tool_use (no matching tool_result yet),
  # which Anthropic rejects. Drop it: the sub-loop has the skill body in
  # its system prompt and the user's request in the preceding history.
  defp fork_messages(messages) do
    case List.last(messages) do
      %AssistantMessage{tool_calls: [_ | _]} -> Enum.drop(messages, -1)
      _ -> messages
    end
  end

  defp build_sub_tools(parent_state, skill) do
    parent_tools = Enum.map(parent_state.agent.tools, &resolve_parent_tool(&1, parent_state))

    parent_tools
    |> maybe_append_skill_tool(skill, parent_state)
    |> Enum.map(&patch_for_skill_location(&1, skill))
  end

  # For file-backed skills, patch every sub-loop tool's context so tools that
  # spawn subprocesses (e.g. Shell) resolve sibling scripts in the skill dir.
  # Sets :cwd to the skill's directory and injects SKILLKIT_SKILL_PATH into
  # the :env map (merging, not overwriting, any host-supplied env).
  defp patch_for_skill_location(sub_tool, %Skill{location: nil}), do: sub_tool

  defp patch_for_skill_location({module, context, definition}, %Skill{location: location}) do
    skill_dir = Path.dirname(location)
    env = Map.put(Map.get(context, :env, %{}), "SKILLKIT_SKILL_PATH", skill_dir)

    patched =
      context
      |> Map.put(:cwd, skill_dir)
      |> Map.put(:env, env)

    {module, patched, definition}
  end

  defp resolve_parent_tool({module, _opts}, parent_state) do
    definition = module.definition()
    context = parent_tool_context(parent_state, definition.name)
    {module, context, definition}
  end

  defp parent_tool_context(parent_state, tool_name) do
    base = base_context(parent_state)

    case SkillKit.Catalog.tool_config(parent_state.agent, tool_name) do
      nil -> base
      {_tool, metadata} -> Map.merge(base, Map.delete(metadata, :tool))
    end
  end

  # Knowledge-only skill (no tool): the sub-loop gets the skill body + inherited
  # parent tools, but no extra tool — and never a silent Shell.
  defp maybe_append_skill_tool(parent_tools, %Skill{tool: nil}, _parent_state), do: parent_tools

  defp maybe_append_skill_tool(parent_tools, %Skill{tool: tool_module} = skill, parent_state) do
    case Enum.any?(parent_tools, fn {m, _c, _d} -> m == tool_module end) do
      true -> parent_tools
      false -> parent_tools ++ [resolve_skill_tool(skill, parent_state)]
    end
  end

  defp resolve_skill_tool(%Skill{tool: tool_module, metadata: metadata}, parent_state) do
    definition = tool_module.definition()
    context = Map.merge(base_context(parent_state), Map.delete(metadata, :tool))
    {tool_module, context, definition}
  end

  defp base_context(parent_state) do
    %{
      agent: parent_state.agent,
      agent_name: root_agent_name(parent_state.agent),
      scope: parent_state.agent.scope
    }
  end

  defp root_agent_name(%{parent_ref: %SkillKit.AgentRef{name: name}}), do: name
  defp root_agent_name(%{name: name}), do: name

  # -- activation outcome handling -----------------------------------------

  defp to_tool_result({:deny, reason}, id) do
    %ToolResult{
      tool_call_id: id,
      name: "activate_skill",
      content: "Denied: #{reason}",
      is_error: true
    }
  end

  defp to_tool_result({:pending, _state}, id) do
    %ToolResult{
      tool_call_id: id,
      name: "activate_skill",
      content: "Skill activation cannot be suspended",
      is_error: true
    }
  end

  defp to_tool_result(text, id) when is_binary(text) do
    %ToolResult{tool_call_id: id, name: "activate_skill", content: text}
  end
end
