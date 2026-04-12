defmodule SkillKit.Agent.ToolDispatch do
  @moduledoc """
  Tool execution dispatch. Classifies, executes, and returns results for
  tool calls from the LLM. Handles plain tools, module skills,
  skill activation, and subagent spawning.

  `execute_one/2` runs a single tool call and returns `{result, side_effects}`
  where side effects are tagged tuples applied by ToolRunner after collection.
  This design supports parallel execution — children can't share or modify
  Server state, so state changes are deferred as data.

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

  @type side_effect ::
          {:activate_skill, Skill.t()}
          | {:subagent, pid(), map()}

  @doc """
  Executes a single tool call. Returns `{result, side_effects}` or
  `{:suspended, execution, side_effects}`.

  Side effects are applied by ToolRunner after collection.
  """
  @spec execute_one(Server.t(), ToolCall.t()) ::
          {ToolResult.t(), [side_effect()]} | {:suspended, ToolExecution.t(), [side_effect()]}
  def execute_one(state, %ToolCall{} = tc) do
    case SkillKit.Catalog.classify(state.agent, tc.name, state.activated_skills) do
      :tool -> execute_command(state, tc)
      {:module_skill, skill} -> execute_module_skill(state, tc, skill)
      :activate_skill -> activate_skill(state, tc)
      :subagent -> spawn_subagent(state, tc)
    end
  end

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

  defp unwrap_result(id, {:deny, reason}) do
    {%ToolResult{tool_call_id: id, content: "Denied: #{reason}", is_error: true}, []}
  end

  defp unwrap_result(_id, {result, side_effects}) when is_list(side_effects) do
    {result, side_effects}
  end

  defp activate_skill(state, %ToolCall{id: id, input: input}) do
    skill_name = Map.get(input, "name", "")
    arguments = Map.get(input, "arguments", "")

    case SkillKit.Catalog.get_skill(state.agent, skill_name) do
      {:ok, skill} ->
        activate_skill_with_hook(state, id, skill, skill_name, arguments)

      {:error, :unauthorized} ->
        result = %ToolResult{
          tool_call_id: id,
          content: "Unauthorized: insufficient scope for skill #{skill_name}",
          is_error: true
        }

        {result, []}

      {:error, reason} ->
        result = %ToolResult{
          tool_call_id: id,
          content: "Error: #{inspect(reason)}",
          is_error: true
        }

        {result, []}
    end
  end

  defp activate_skill_with_hook(state, id, skill, skill_name, arguments) do
    hook_context = %{
      skill: skill,
      skill_name: skill_name,
      arguments: arguments,
      agent_name: state.agent.name,
      scope: state.agent.scope
    }

    result =
      Hooks.call(state.agent, :skill_activation, hook_context, fn ->
        do_activate_skill(state, id, skill, skill_name, arguments, hook_context)
      end)

    unwrap_result(id, result)
  end

  defp do_activate_skill(state, id, skill, _skill_name, arguments, hook_context) do
    scope_context = %{agent: state.agent.name, skill: skill.name}
    result = render_and_activate(state, id, skill, arguments, scope_context)
    {result, Map.put(hook_context, :result, result)}
  end

  defp render_and_activate(state, id, skill, arguments, scope_context) do
    rendered = Skill.render(skill, %{"arguments" => arguments}, state.agent.scope, scope_context)
    handle_skill_activation(state, id, skill, rendered)
  end

  defp handle_skill_activation(state, id, skill, {:ok, rendered_body}) do
    already_activated = Enum.any?(state.activated_skills, &(&1.name == skill.name))

    side_effects =
      if skill.tool != SkillKit.Tools.Shell and not already_activated do
        [{:activate_skill, skill}]
      else
        []
      end

    {%ToolResult{tool_call_id: id, content: rendered_body}, side_effects}
  end

  defp execute_module_skill(state, %ToolCall{id: id, input: input}, skill) do
    hook_context = %{
      tool: skill.tool,
      input: input,
      skill: skill,
      scope: state.agent.scope,
      agent_name: state.agent.name
    }

    result =
      Hooks.call(state.agent, :tool_use, hook_context, fn ->
        do_execute_module_skill(state, id, skill, input, hook_context)
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

  defp do_execute_module_skill(state, id, skill, input, hook_context) do
    source_config = Map.get(skill.metadata, "source_config", [])

    context =
      %{scope: state.agent.scope, agent_name: state.agent.name}
      |> Map.merge(Map.new(source_config))

    execution = %ToolExecution{skill: skill, input: input, context: context, tool: skill.tool}

    case ToolExecution.execute(execution) do
      {:ok, exec} ->
        result = %ToolResult{tool_call_id: id, content: to_string(exec.result)}
        {result, Map.put(hook_context, :result, exec.result)}

      {:error, exec} ->
        result = %ToolResult{tool_call_id: id, content: inspect(exec.result), is_error: true}
        {result, Map.put(hook_context, :result, exec.result)}

      {:pending, exec} ->
        {{:suspended, exec}, hook_context}
    end
  end

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

    parent_ref = %SkillKit.AgentRef{
      name: state.agent.name,
      registry: state.agent.registry,
      supervisor_pid: self()
    }

    child_agent = %{
      agent_def
      | name: subagent_name,
        depth: state.agent.depth + 1,
        parent_ref: parent_ref,
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

  defp get_last_assistant_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %AssistantMessage{content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end
end
