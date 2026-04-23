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
  results) are forwarded to the parent's `caller` pid tagged with a
  synthetic agent name `"<parent>/skill:<skill_name>"`, so chat
  printers that match by agent-name prefix surface them alongside the
  parent's own events.

  Wrapped in `Hooks.call(:skill_activation)` so
  `[:skill_kit, :skill_activation, :start/:stop]` telemetry fires and
  `:pre_skill_activation` / `:post_skill_activation` hooks can observe
  or deny the activation.
  """

  alias SkillKit.Agent.Server
  alias SkillKit.Agent.StreamAccumulator
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.Event.Usage
  alias SkillKit.Hooks
  alias SkillKit.LLM
  alias SkillKit.Skill
  alias SkillKit.ToolExecution
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.ToolResult

  @spec run(Server.t(), Skill.t(), String.t(), String.t()) :: ToolResult.t()
  def run(%Server{} = parent_state, %Skill{} = skill, body, tool_call_id)
      when is_binary(body) and is_binary(tool_call_id) do
    hook_context = %{
      skill: skill,
      agent_name: parent_state.agent.name
    }

    Hooks.call(parent_state.agent, :skill_activation, hook_context, fn ->
      text = do_run(parent_state, skill, body)
      {text, Map.put(hook_context, :result, text)}
    end)
    |> to_tool_result(tool_call_id)
  end

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

  # -- sub-loop ------------------------------------------------------------

  defp do_run(parent_state, skill, body) do
    sub_system = parent_state.agent.system_prompt <> "\n\n" <> body
    sub_tools = build_sub_tools(parent_state, skill)
    tool_defs = Enum.map(sub_tools, fn {_module, _ctx, def} -> def end)
    sub_messages = fork_messages(parent_state.messages)

    loop(parent_state, skill, sub_system, sub_messages, sub_tools, tool_defs)
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

  defp loop(parent_state, skill, system, messages, sub_tools, tool_defs) do
    case LLM.stream(messages,
           model: parent_state.agent.model,
           system: system,
           tools: tool_defs
         ) do
      {:ok, stream} ->
        response = consume_stream(stream, parent_state, skill)
        handle_response(response, parent_state, skill, system, messages, sub_tools, tool_defs)

      {:error, reason} ->
        "Skill activation error: #{inspect(reason)}"
    end
  end

  defp handle_response(%AssistantMessage{tool_calls: []} = response, _p, _s, _sys, _m, _st, _td) do
    response.content || ""
  end

  defp handle_response(
         %AssistantMessage{tool_calls: tool_calls} = response,
         parent_state,
         skill,
         system,
         messages,
         sub_tools,
         tool_defs
       ) do
    messages = messages ++ [response]
    results = Enum.map(tool_calls, &execute_tool_call(&1, parent_state, skill, sub_tools))
    messages = messages ++ results
    loop(parent_state, skill, system, messages, sub_tools, tool_defs)
  end

  # -- stream consumption --------------------------------------------------

  defp consume_stream(stream, parent_state, skill) do
    sub_name = sub_agent_name(parent_state, skill)

    acc =
      Enum.reduce(
        stream,
        StreamAccumulator.new(),
        &process_event(&1, &2, parent_state.agent, sub_name)
      )

    StreamAccumulator.finalize(acc)
  end

  defp process_event(%Delta{text: text}, acc, agent, sub_name) do
    notify_caller(agent, %Delta{text: text, agent: sub_name})
    %{acc | text: acc.text <> text}
  end

  defp process_event(%ToolCallStart{} = event, acc, agent, sub_name) do
    notify_caller(agent, %{event | agent: sub_name})
    acc
  end

  defp process_event(%ToolCallComplete{} = event, acc, agent, sub_name) do
    notify_caller(agent, %{event | agent: sub_name})
    tool_call = %ToolCall{id: event.id, name: event.name, input: event.input}
    %{acc | tool_calls: acc.tool_calls ++ [tool_call]}
  end

  defp process_event(%Usage{} = usage, acc, _agent, _sub_name) do
    merged = %{
      input_tokens: acc.usage.input_tokens + usage.input_tokens,
      output_tokens: acc.usage.output_tokens + usage.output_tokens
    }

    %{acc | usage: merged}
  end

  defp process_event(%Done{}, acc, _agent, _sub_name), do: acc
  defp process_event(_other, acc, _agent, _sub_name), do: acc

  # -- tool routing & execution --------------------------------------------

  defp build_sub_tools(parent_state, skill) do
    parent_tools = Enum.map(parent_state.agent.tools, &resolve_parent_tool(&1, parent_state))
    maybe_append_skill_tool(parent_tools, skill, parent_state)
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

  defp maybe_append_skill_tool(parent_tools, %Skill{tool: tool_module} = skill, parent_state) do
    if Enum.any?(parent_tools, fn {m, _c, _d} -> m == tool_module end) do
      parent_tools
    else
      parent_tools ++ [resolve_skill_tool(skill, parent_state)]
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

  defp execute_tool_call(
         %ToolCall{id: id, name: name, input: input},
         parent_state,
         skill,
         sub_tools
       ) do
    result = run_tool(find_tool(sub_tools, name), id, name, input)
    notify_caller(parent_state.agent, tag_result(result, parent_state, skill))
    result
  end

  defp find_tool(sub_tools, name) do
    Enum.find(sub_tools, fn {_m, _c, def} -> def.name == name end)
  end

  defp run_tool(nil, id, name, _input) do
    %ToolResult{tool_call_id: id, content: "Unknown tool: #{name}", is_error: true}
  end

  defp run_tool({module, context, _def}, id, _name, input) do
    exec = %ToolExecution{tool: module, input: input, context: context}
    to_result(ToolExecution.execute(exec), id)
  end

  defp to_result({:ok, execution}, id) do
    %ToolResult{tool_call_id: id, content: extract_output(execution.result)}
  end

  defp to_result({:error, execution}, id) do
    %ToolResult{tool_call_id: id, content: extract_error(execution), is_error: true}
  end

  defp to_result({:pending, _execution}, id) do
    %ToolResult{
      tool_call_id: id,
      content: "Tool suspension is not supported in skill sub-loops",
      is_error: true
    }
  end

  defp extract_output({:ok, output}), do: ensure_non_empty(output)
  defp extract_output(output) when is_binary(output), do: ensure_non_empty(output)
  defp extract_output(other), do: inspect(other)

  defp extract_error(execution) do
    case execution.result do
      {output, _code} -> ensure_non_empty(output)
      reason when is_binary(reason) -> ensure_non_empty(reason)
      _ -> "Execution failed"
    end
  end

  defp ensure_non_empty(""), do: "(no output)"
  defp ensure_non_empty(nil), do: "(no output)"
  defp ensure_non_empty(str) when is_binary(str), do: str

  # -- notifications -------------------------------------------------------

  defp tag_result(%ToolResult{} = result, parent_state, skill) do
    %{result | agent: sub_agent_name(parent_state, skill)}
  end

  defp notify_caller(%{caller: nil}, _event), do: :ok
  defp notify_caller(%{caller: pid}, event), do: send(pid, event)

  defp sub_agent_name(parent_state, skill) do
    "#{parent_state.agent.name}/skill:#{skill.name}"
  end
end
