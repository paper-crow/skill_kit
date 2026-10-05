defmodule SkillKit.Agent.ToolDispatch do
  @moduledoc """
  Tool execution dispatch. Classifies, executes, and returns results for
  tool calls from the LLM. Handles plain tools, skill activation, and
  subagent spawning.

  `execute_one/2` runs a single tool call and returns `{result, side_effects}`
  where side effects are tagged tuples applied by ToolRunner after collection.
  This design supports parallel execution — children can't share or modify
  Server state, so state changes are deferred as data.

  Skill activation runs the skill as a forked sub-conversation in the
  parent agent's process via `SkillKit.Agent.SkillActivation`. The parent
  receives the sub-loop's final text as the `activate_skill` tool's
  result. No child agent supervision tree is spawned.

  Subagent delegation returns immediately (the subagent runs independently).
  Tools that need external input return `{:suspended, execution, side_effects}`
  to suspend rather than blocking.
  """

  alias SkillKit.Agent.Server
  alias SkillKit.Agent.SkillActivation
  alias SkillKit.Hooks
  alias SkillKit.Runtime
  alias SkillKit.ToolExecution
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.ToolResult

  @type side_effect :: {:subagent, pid(), map()}

  @doc """
  Executes a single tool call. Returns `{result, side_effects}` or
  `{:suspended, execution, side_effects}`.

  Side effects are applied by ToolRunner after collection.
  """
  @spec execute_one(Server.t(), ToolCall.t()) ::
          {ToolResult.t(), [side_effect()]} | {:suspended, ToolExecution.t(), [side_effect()]}
  def execute_one(state, %ToolCall{} = tc) do
    case SkillKit.Catalog.classify(state.agent, tc.name) do
      :tool -> execute_command(state, tc)
      :activate_skill -> activate_skill(state, tc)
      :subagent -> spawn_subagent(state, tc)
    end
  end

  defp execute_command(state, %ToolCall{id: id, name: name, input: input}) do
    dispatch_known_tool(find_tool(state, name), state, id, name, input)
  end

  defp dispatch_known_tool(nil, _state, id, name, _input) do
    {%ToolResult{
       tool_call_id: id,
       content: "Unknown tool: #{name}",
       is_error: true
     }, []}
  end

  defp dispatch_known_tool(tool, state, id, name, input) do
    tool_context = build_context(state, name)

    hook_context = %{
      tool: tool,
      input: input,
      skill: nil,
      scope: state.agent.scope,
      agent_name: state.agent.name
    }

    result =
      Hooks.call(state.agent, :tool_use, hook_context, fn ->
        do_execute_command(id, tool, input, tool_context, hook_context)
      end)

    dispatch_hook_result(result, id)
  end

  defp dispatch_hook_result({:suspended, execution}, _id), do: {:suspended, execution, []}

  defp dispatch_hook_result({:deny, reason}, id) do
    {%ToolResult{tool_call_id: id, content: "Denied: #{reason}", is_error: true}, []}
  end

  defp dispatch_hook_result(tool_result, _id), do: {tool_result, []}

  defp do_execute_command(id, tool, input, tool_context, hook_context) do
    exec = %ToolExecution{tool: tool, input: input, context: tool_context}

    case ToolExecution.execute(exec) do
      {:ok, execution} ->
        result = %ToolResult{tool_call_id: id, content: extract_output(execution.result)}
        {result, Map.put(hook_context, :result, execution.result)}

      {:error, execution} ->
        result = %ToolResult{
          tool_call_id: id,
          content: extract_error(execution),
          is_error: true
        }

        {result, Map.put(hook_context, :result, execution.result)}

      {:pending, execution} ->
        {{:suspended, execution}, hook_context}
    end
  end

  defp find_tool(state, tool_name) do
    case SkillKit.Catalog.tool_config(state.agent, tool_name) do
      nil -> nil
      {tool, _metadata} -> tool
    end
  end

  @doc """
  Builds the `context` map passed to `Tool.execute/1` for a given tool
  call name.

  The context contains:
    * `:agent` — the full agent struct (scope, name, etc.).
    * `:agent_name` — the root agent's name. For an activate_skill child
      this is the parent's name, not the ephemeral child name — so
      state that outlives the child (e.g. a webhook registration) is
      bound to the right agent.
    * `:scope` — shortcut to `agent.scope`.
    * Tool-specific metadata merged in (e.g., `:cwd`, `:env` for Shell;
      `:supervisor`, `:verifiers` for Webhook).
  """
  def build_context(state, tool_name) do
    base_context = %{
      agent: state.agent,
      agent_name: root_agent_name(state.agent),
      scope: state.agent.scope
    }

    case SkillKit.Catalog.tool_config(state.agent, tool_name) do
      nil -> base_context
      {_tool, metadata} -> Map.merge(base_context, Map.delete(metadata, :tool))
    end
  end

  defp root_agent_name(%{parent_ref: %SkillKit.AgentRef{name: name}}), do: name
  defp root_agent_name(%{name: name}), do: name

  @doc false
  def extract_output({:ok, output}), do: extract_output(output)
  def extract_output(output) when is_binary(output), do: ensure_non_empty(output)
  def extract_output([block | _] = blocks) when is_map(block), do: blocks
  def extract_output(other), do: inspect(other)

  @doc false
  def extract_error(execution) do
    case execution.result do
      {output, _code} -> ensure_non_empty(output)
      reason when is_binary(reason) -> ensure_non_empty(reason)
      _ -> "Execution failed"
    end
  end

  defp ensure_non_empty(""), do: "(no output)"
  defp ensure_non_empty(str) when is_binary(str), do: str
  defp ensure_non_empty(nil), do: "(no output)"

  # --- Skill Activation (in-process sub-loop) ---

  defp activate_skill(state, %ToolCall{id: id, input: input}) do
    {SkillActivation.dispatch(state, id, input), []}
  end

  # --- Subagent Spawning ---

  defp spawn_subagent(
         %{agent: %{depth: depth, max_agent_depth: max}},
         %ToolCall{id: id}
       )
       when depth >= max do
    result = %ToolResult{
      tool_call_id: id,
      content: "Cannot spawn subagent: max depth (#{max}) reached.",
      is_error: true
    }

    {result, []}
  end

  defp spawn_subagent(state, %ToolCall{id: id, name: name, input: input}) do
    task = Map.get(input, "task", "")
    start_known_subagent(SkillKit.Catalog.get_agent(state.agent, name), state, id, name, task)
  end

  defp start_known_subagent({:error, :not_found}, _state, id, name, _task) do
    result = %ToolResult{
      tool_call_id: id,
      content: "Unknown agent: #{name}",
      is_error: true
    }

    {result, []}
  end

  defp start_known_subagent({:ok, agent_def}, state, id, name, task) do
    spawn_subagent_with_hook(state, id, name, task, agent_def)
  end

  defp spawn_subagent_with_hook(state, id, name, task, agent_def) do
    hook_context = %{
      name: name,
      task: task,
      agent_name: state.agent.name,
      depth: state.agent.depth
    }

    result =
      Hooks.call(state.agent, :subagent, hook_context, fn ->
        spawn_result = do_spawn_subagent(state, id, name, task, agent_def)
        {spawn_result, Map.put(hook_context, :result, spawn_result)}
      end)

    unwrap_result(id, result)
  end

  defp do_spawn_subagent(state, id, name, task, agent_def) do
    subagent_name = "#{state.agent.name}/#{name}-#{:erlang.unique_integer([:positive])}"

    child_agent = %{
      agent_def
      | name: subagent_name,
        model: agent_def.model || state.agent.model,
        depth: state.agent.depth + 1,
        parent_ref: build_parent_ref(state),
        tools: state.agent.tools,
        skills: state.agent.skills,
        runtime: state.agent.runtime,
        registry: :"skill_kit_registry_#{:erlang.unique_integer([:positive])}"
    }

    case Runtime.start_agent(child_agent) do
      {:ok, agent_ref} ->
        [{server_pid, _}] = Registry.lookup(agent_ref.registry, {subagent_name, :server})

        parent_intent = get_last_assistant_content(state.messages)

        entry = %{
          name: name,
          task: task,
          parent_intent: parent_intent,
          agent_ref: agent_ref
        }

        SkillKit.send_message(agent_ref, task)

        result = %ToolResult{
          tool_call_id: id,
          content: """
          Subagent #{name} started in the background. Its result will arrive as a
          system message when complete. Tell the user what you delegated and what
          to expect, in whatever way fits the conversation. Continue with other
          work or pause your turn as appropriate.
          """
        }

        {result, [{:subagent, server_pid, entry}]}

      {:error, reason} ->
        result = %ToolResult{
          tool_call_id: id,
          content: "Failed to start subagent #{name}: #{inspect(reason)}",
          is_error: true
        }

        {result, []}
    end
  end

  # --- Shared Helpers ---

  defp build_parent_ref(state) do
    %SkillKit.AgentRef{
      name: state.agent.name,
      registry: state.agent.registry,
      supervisor_pid: self()
    }
  end

  defp unwrap_result(id, {:deny, reason}) do
    {%ToolResult{tool_call_id: id, content: "Denied: #{reason}", is_error: true}, []}
  end

  defp unwrap_result(_id, {result, side_effects}) when is_list(side_effects) do
    {result, side_effects}
  end

  defp get_last_assistant_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %AssistantMessage{content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end
end
