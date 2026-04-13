defmodule SkillKit.Agent.ToolDispatch do
  @moduledoc """
  Tool execution dispatch. Classifies, executes, and returns results for
  tool calls from the LLM. Handles plain tools, skill activation (via
  child agent forking), and subagent spawning.

  `execute_one/2` runs a single tool call and returns `{result, side_effects}`
  where side effects are tagged tuples applied by ToolRunner after collection.
  This design supports parallel execution — children can't share or modify
  Server state, so state changes are deferred as data.

  Skill activation forks the parent agent's context into a child agent that
  runs autonomously with the skill's instructions and tools. The parent
  receives the result via `:DOWN` monitoring, avoiding state leaks.

  Subagent delegation returns immediately (the subagent runs independently).
  Tools that need external input return `{:suspended, execution, side_effects}`
  to suspend rather than blocking.
  """

  alias SkillKit.Agent.Server
  alias SkillKit.Hooks
  alias SkillKit.Runtime
  alias SkillKit.Skill
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
    result =
      case SkillKit.Catalog.classify(state.agent, tc.name) do
        :tool -> execute_command(state, tc)
        :activate_skill -> activate_skill(state, tc)
        :subagent -> spawn_subagent(state, tc)
      end

    wrap_error(result, tc.id)
  end

  defp wrap_error({:error, reason}, id) do
    {%ToolResult{tool_call_id: id, content: "Error: #{inspect(reason)}", is_error: true}, []}
  end

  defp wrap_error(result, _id), do: result

  defp execute_command(state, %ToolCall{id: id, input: input}) do
    tool = find_tool(state)
    tool_context = build_tool_context(state)

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

    case result do
      {:suspended, execution} ->
        {:suspended, execution, []}

      {:deny, reason} ->
        {%ToolResult{tool_call_id: id, content: "Denied: #{reason}", is_error: true}, []}

      tool_result ->
        {unwrap_tool_result(id, tool_result), []}
    end
  end

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

  defp find_tool(state) do
    case SkillKit.Catalog.tool_config(state.agent) do
      nil -> SkillKit.Tools.Shell
      {tool, _metadata} -> tool
    end
  end

  defp build_tool_context(state) do
    base_context = %{scope: state.agent.scope}

    case SkillKit.Catalog.tool_config(state.agent) do
      nil -> base_context
      {_tool, metadata} -> merge_tool_config(base_context, metadata)
    end
  end

  defp merge_tool_config(context, metadata) do
    context
    |> maybe_put_cwd(metadata)
    |> maybe_put_env(metadata)
  end

  defp maybe_put_cwd(context, %{cwd: cwd}), do: Map.put(context, :cwd, cwd)
  defp maybe_put_cwd(context, _metadata), do: context

  defp maybe_put_env(context, %{env: env}), do: Map.put(context, :env, env)
  defp maybe_put_env(context, _metadata), do: context

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
  defp ensure_non_empty(str) when is_binary(str), do: str
  defp ensure_non_empty(nil), do: "(no output)"

  defp unwrap_tool_result(id, {:deny, reason}) do
    %ToolResult{tool_call_id: id, content: "Denied: #{reason}", is_error: true}
  end

  defp unwrap_tool_result(_id, result), do: result

  # --- Skill Activation (fork into child agent) ---

  defp activate_skill(state, %ToolCall{id: id, input: input}) do
    skill_name = Map.get(input, "name", "")

    with {:ok, skill} <- SkillKit.Catalog.get_skill(state.agent, skill_name),
         {:ok, body} <- render_skill(skill, state),
         {:ok, agent} <- build_skill_agent(skill, body, state) do
      start_skill_agent(agent, skill, state, id)
    end
  end

  defp render_skill(skill, state) do
    scope_context = %{agent: state.agent.name, skill: skill.name}
    Skill.render(skill, %{}, state.agent.scope, scope_context)
  end

  defp build_skill_agent(skill, body, state) do
    {:ok,
     %{
       state.agent
       | name: "#{state.agent.name}/skill:#{skill.name}-#{:erlang.unique_integer([:positive])}",
         system_prompt: state.agent.system_prompt <> "\n\n" <> body,
         skills: skill_providers(skill),
         depth: state.agent.depth + 1,
         parent_ref: build_parent_ref(state),
         registry: :"skill_kit_registry_#{:erlang.unique_integer([:positive])}",
         conversation_store: nil,
         initial_messages: state.messages
     }}
  end

  defp skill_providers(%{tool: tool}) when tool != SkillKit.Tools.Shell do
    [{tool, []}]
  end

  defp skill_providers(_skill), do: []

  defp start_skill_agent(agent, skill, state, id) do
    case Runtime.start_agent(agent) do
      {:ok, agent_ref} ->
        [{server_pid, _}] = Registry.lookup(agent_ref.registry, {agent.name, :server})

        entry = %{
          name: skill.name,
          task: "skill:#{skill.name}",
          parent_intent: get_last_assistant_content(state.messages),
          agent_ref: agent_ref
        }

        result = %ToolResult{
          tool_call_id: id,
          content: "Running skill #{skill.name}..."
        }

        {result, [{:subagent, server_pid, entry}]}

      {:error, reason} ->
        {%ToolResult{
           tool_call_id: id,
           content: "Failed to start skill agent: #{inspect(reason)}",
           is_error: true
         }, []}
    end
  end

  # --- Subagent Spawning ---

  defp spawn_subagent(state, %ToolCall{id: id, name: name, input: input}) do
    task = Map.get(input, "task", "")

    if state.agent.depth >= state.agent.max_agent_depth do
      result = %ToolResult{
        tool_call_id: id,
        content: "Cannot spawn subagent: max depth (#{state.agent.max_agent_depth}) reached.",
        is_error: true
      }

      {result, []}
    else
      case SkillKit.Catalog.get_agent(state.agent, name) do
        {:error, :not_found} ->
          result = %ToolResult{
            tool_call_id: id,
            content: "Unknown agent: #{name}",
            is_error: true
          }

          {result, []}

        {:ok, agent_def} ->
          spawn_subagent_with_hook(state, id, name, task, agent_def)
      end
    end
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
          content: "Delegated to #{name}. You will receive the result when it completes."
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
