defmodule SkillKit.Agent.Server do
  @moduledoc """
  Core agent process. Drives the LLM loop, manages subagents.

  The loop runs synchronously within `handle_info({:mailbox_flush, ...})`.
  Streams from `SkillKit.LLM`, decodes responses, routes tool calls,
  and loops until no more tool calls are returned.
  """

  use GenServer

  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.Event.Usage
  alias SkillKit.Hooks
  alias SkillKit.Runtime
  alias SkillKit.Skill
  alias SkillKit.Telemetry
  alias SkillKit.ToolExecution
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.SystemMessage
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.ToolResult

  defstruct [
    :agent,
    halted: false,
    messages: [],
    subagents: %{},
    pending_requests: %{},
    activated_skills: []
  ]

  @type t :: %__MODULE__{
          agent: SkillKit.Agent.t(),
          halted: boolean(),
          messages: list(),
          subagents: map(),
          pending_requests: map(),
          activated_skills: [SkillKit.Skill.t()]
        }

  def start_link(%SkillKit.Agent{} = agent) do
    GenServer.start_link(__MODULE__, agent)
  end

  @impl true
  def init(%SkillKit.Agent{} = agent) do
    Registry.register(agent.registry, {agent.name, :server}, [])

    messages = load_conversation(agent.conversation_store, agent.name, catalog(agent))

    state = %__MODULE__{
      agent: agent,
      messages: messages,
      halted: false
    }

    try do
      Hooks.cast(catalog(agent), :pre_agent, %{
        agent_name: agent.name,
        definition: agent
      })
    catch
      :exit, _reason -> :ok
    end

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    try do
      Hooks.cast(catalog(state.agent), :post_agent, %{
        agent_name: state.agent.name,
        definition: state.agent
      })
    catch
      :exit, _reason -> :ok
    end

    :ok
  end

  # --- Agent Loop ---

  @impl true
  def handle_info({:mailbox_flush, _new_messages}, %{halted: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:mailbox_flush, new_messages}, state) do
    turn_context = %{agent_name: state.agent.name, message_count: length(new_messages)}

    state =
      Hooks.call(catalog(state.agent), :turn, turn_context, fn ->
        updated = run_agent_loop(state, new_messages)
        {updated, turn_context}
      end)

    save_conversation(state)

    {:noreply, state}
  end

  # Subagent finished — inject rich resume message via mailbox
  @impl true
  def handle_info({:subagent_result, pid, result}, state) do
    case Map.pop(state.subagents, pid) do
      {nil, _} ->
        {:noreply, state}

      {entry, subagents} ->
        Process.demonitor(entry.monitor_ref, [:flush])
        state = %{state | subagents: subagents}

        intent = entry.parent_intent || "N/A"

        message = %SystemMessage{
          content: """
          [Subagent Complete] #{entry.name} finished the task you delegated.

          **Your plan before delegating:** "#{intent}"
          **Task you delegated:** "#{entry.task}"
          **Result:**
          #{result}

          Continue with your plan.\
          """
        }

        Hooks.cast(catalog(state.agent), :post_subagent, %{
          name: entry.name,
          task: entry.task,
          result: result,
          agent_name: state.agent.name
        })

        cast_to_mailbox(state, {:message, message})
        {:noreply, state}
    end
  end

  # Subagent crashed — inject error as System message
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pop_by_monitor(state.subagents, ref) do
      nil ->
        {:noreply, state}

      {entry, subagents} ->
        state = %{state | subagents: subagents}

        message = %SystemMessage{
          content:
            "[Subagent Failed] #{entry.name} crashed while working on: #{entry.task}\n" <>
              "Reason: #{inspect(reason)}"
        }

        cast_to_mailbox(state, {:message, message})
        {:noreply, state}
    end
  end

  # --- Core Loop ---

  defp run_agent_loop(%{halted: true} = state, _new_messages), do: state

  defp run_agent_loop(state, new_messages) do
    state = %{state | messages: state.messages ++ new_messages}

    tools =
      SkillKit.Catalog.tool_definitions(catalog(state.agent),
        subagent: state.agent.depth > 0,
        activated_skills: state.activated_skills
      )

    llm_context = %{
      agent_name: state.agent.name,
      model: state.agent.model,
      message_count: length(state.messages),
      tool_count: length(tools)
    }

    llm_result = hooked_llm_request(state, tools, llm_context)

    case llm_result do
      {:deny, reason} ->
        notify_caller(state, %EventError{agent: state.agent.name, reason: reason})
        state

      {:ok, event_stream} ->
        acc = Enum.reduce(event_stream, new_accumulator(), &process_event(&1, &2, state))
        response = finalize_response(acc)
        state = %{state | messages: state.messages ++ [response]}
        handle_response(response, state)

      {:error, reason} ->
        notify_caller(state, %EventError{agent: state.agent.name, reason: reason})
        state
    end
  end

  defp hooked_llm_request(state, tools, llm_context) do
    Hooks.call(catalog(state.agent), :llm_request, llm_context, fn ->
      result = stream(state, tools)
      {result, llm_context}
    end)
  end

  defp handle_response(%AssistantMessage{content: nil, tool_calls: []}, state) do
    # Empty response (no content, no tool calls) — discard it from messages
    %{state | messages: List.delete_at(state.messages, -1)}
  end

  defp handle_response(%AssistantMessage{tool_calls: []} = response, state) do
    notify_caller(state, %{response | agent: state.agent.name})
    state
  end

  defp handle_response(%AssistantMessage{tool_calls: tool_calls}, state) do
    {results, state} = execute_tool_calls(tool_calls, state)
    state = %{state | messages: state.messages ++ results}
    run_agent_loop(state, [])
  end

  defp execute_tool_calls(tool_calls, state) do
    Enum.map_reduce(tool_calls, state, fn tc, acc ->
      {result, acc} =
        case SkillKit.Catalog.classify(catalog(acc.agent), tc.name, acc.activated_skills) do
          :tool -> {execute_command(tc, acc), acc}
          {:module_skill, skill} -> {execute_module_skill(tc, skill, acc), acc}
          :activate_skill -> activate_skill(tc, acc)
          :subagent -> spawn_subagent(tc, acc)
          :builtin -> handle_builtin(tc, acc)
        end

      notify_caller(acc, %{result | agent: acc.agent.name})

      {result, acc}
    end)
  end

  defp execute_command(%ToolCall{id: id, input: input}, state) do
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
      Hooks.call(catalog(state.agent), :tool_use, hook_context, fn ->
        do_execute_command(id, tool, input, tool_context, hook_context)
      end)

    unwrap_tool_result(id, result)
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

      {:pending, _execution} ->
        result = %ToolResult{
          tool_call_id: id,
          content: "Command requires approval (not yet supported).",
          is_error: true
        }

        {result, hook_context}
    end
  end

  defp find_tool(state) do
    case SkillKit.Catalog.tool_config(catalog(state.agent)) do
      nil -> SkillKit.Tools.Shell
      {tool, _metadata} -> tool
    end
  end

  defp build_tool_context(state) do
    base_context = %{scope: state.agent.scope}

    case SkillKit.Catalog.tool_config(catalog(state.agent)) do
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

  defp unwrap_stateful_result(id, {:deny, reason}, state) do
    result = %ToolResult{tool_call_id: id, content: "Denied: #{reason}", is_error: true}
    {result, state}
  end

  defp unwrap_stateful_result(_id, result, _state), do: result

  defp activate_skill(%ToolCall{id: id, input: input}, state) do
    skill_name = Map.get(input, "name", "")
    arguments = Map.get(input, "arguments", "")

    case SkillKit.Catalog.get_skill(catalog(state.agent), skill_name) do
      {:ok, skill} ->
        activate_skill_with_hook(id, skill, skill_name, arguments, state)

      {:error, :unauthorized} ->
        result = %ToolResult{
          tool_call_id: id,
          content: "Unauthorized: insufficient scope for skill #{skill_name}",
          is_error: true
        }

        {result, state}

      {:error, reason} ->
        result = %ToolResult{
          tool_call_id: id,
          content: "Error: #{inspect(reason)}",
          is_error: true
        }

        {result, state}
    end
  end

  defp activate_skill_with_hook(id, skill, skill_name, arguments, state) do
    hook_context = %{
      skill: skill,
      skill_name: skill_name,
      arguments: arguments,
      agent_name: state.agent.name,
      scope: state.agent.scope
    }

    result =
      Hooks.call(catalog(state.agent), :skill_activation, hook_context, fn ->
        do_activate_skill(id, skill, skill_name, arguments, state, hook_context)
      end)

    unwrap_stateful_result(id, result, state)
  end

  defp do_activate_skill(id, skill, skill_name, arguments, state, hook_context) do
    scope_context = %{agent: state.agent.name, skill: skill_name}
    result = render_and_activate(id, skill, arguments, state, scope_context)
    {result, Map.put(hook_context, :result, result)}
  end

  defp render_and_activate(id, skill, arguments, state, scope_context) do
    rendered = Skill.render(skill, %{"arguments" => arguments}, state.agent.scope, scope_context)
    handle_skill_activation(id, skill, rendered, state)
  end

  defp handle_skill_activation(id, skill, {:ok, rendered_body}, state) do
    already_activated = Enum.any?(state.activated_skills, &(&1.name == skill.name))

    state =
      if skill.tool != SkillKit.Tools.Shell and not already_activated do
        %{state | activated_skills: [skill | state.activated_skills]}
      else
        state
      end

    {%ToolResult{tool_call_id: id, content: rendered_body}, state}
  end

  defp execute_module_skill(%ToolCall{id: id, input: input}, skill, state) do
    hook_context = %{
      tool: skill.tool,
      input: input,
      skill: skill,
      scope: state.agent.scope,
      agent_name: state.agent.name
    }

    result =
      Hooks.call(catalog(state.agent), :tool_use, hook_context, fn ->
        do_execute_module_skill(id, skill, input, state, hook_context)
      end)

    unwrap_tool_result(id, result)
  end

  defp do_execute_module_skill(id, skill, input, state, hook_context) do
    source_config = Map.get(skill.metadata, "source_config", [])

    context =
      %{scope: state.agent.scope, agent_name: state.agent.name}
      |> Map.merge(Map.new(source_config))

    execution = %ToolExecution{skill: skill, input: input, context: context}

    result =
      case apply(skill.tool, :execute, [execution]) do
        {:ok, value} ->
          %ToolResult{tool_call_id: id, content: to_string(value)}

        {:error, reason} ->
          %ToolResult{tool_call_id: id, content: inspect(reason), is_error: true}
      end

    {result, Map.put(hook_context, :result, result)}
  end

  defp spawn_subagent(%ToolCall{id: id, name: name, input: input}, state) do
    task = Map.get(input, "task", "")

    if state.agent.depth >= state.agent.max_agent_depth do
      result = %ToolResult{
        tool_call_id: id,
        content: "Cannot spawn subagent: max depth (#{state.agent.max_agent_depth}) reached.",
        is_error: true
      }

      {result, state}
    else
      case SkillKit.Catalog.get_agent(catalog(state.agent), name) do
        {:error, :not_found} ->
          result = %ToolResult{
            tool_call_id: id,
            content: "Unknown agent: #{name}",
            is_error: true
          }

          {result, state}

        {:ok, agent_def} ->
          spawn_subagent_with_hook(id, name, task, agent_def, state)
      end
    end
  end

  defp spawn_subagent_with_hook(id, name, task, agent_def, state) do
    hook_context = %{
      name: name,
      task: task,
      agent_name: state.agent.name,
      depth: state.agent.depth
    }

    result =
      Hooks.call(catalog(state.agent), :subagent, hook_context, fn ->
        spawn_result = do_spawn_subagent(id, name, task, agent_def, state)
        {spawn_result, Map.put(hook_context, :result, spawn_result)}
      end)

    unwrap_stateful_result(id, result, state)
  end

  defp do_spawn_subagent(id, name, task, agent_def, state) do
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
        monitor_ref = Process.monitor(server_pid)

        parent_intent = get_last_assistant_content(state.messages)

        subagents =
          Map.put(state.subagents, server_pid, %{
            name: name,
            task: task,
            monitor_ref: monitor_ref,
            parent_intent: parent_intent,
            agent_ref: agent_ref
          })

        updated_state = %{state | subagents: subagents}

        SkillKit.send_message(agent_ref, task)

        result = %ToolResult{
          tool_call_id: id,
          content: "Delegated to #{name}. You will receive the result when it completes."
        }

        {result, updated_state}

      {:error, reason} ->
        result = %ToolResult{
          tool_call_id: id,
          content: "Failed to start subagent #{name}: #{inspect(reason)}",
          is_error: true
        }

        {result, state}
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

  defp handle_builtin(%ToolCall{id: id, name: "report_result", input: input}, state) do
    result = Map.get(input, "result", "")

    case lookup_parent(state) do
      {:ok, parent_pid} ->
        send(parent_pid, {:subagent_result, self(), result})

      :not_found ->
        Telemetry.event([:agent, :orphaned_result], %{}, %{
          agent_name: state.agent.name,
          parent_name: state.agent.parent_ref && state.agent.parent_ref.name,
          result: result
        })
    end

    state = %{state | halted: true}
    {%ToolResult{tool_call_id: id, content: "Result reported successfully."}, state}
  end

  defp handle_builtin(%ToolCall{id: id, name: "report_status"}, state) do
    {%ToolResult{tool_call_id: id, content: "Status acknowledged."}, state}
  end

  defp handle_builtin(%ToolCall{id: id, name: name}, state) do
    {%ToolResult{tool_call_id: id, content: "Unknown builtin: #{name}", is_error: true}, state}
  end

  defp lookup_parent(%{agent: %{parent_ref: nil}}), do: :not_found

  defp lookup_parent(%{agent: %{parent_ref: %SkillKit.AgentRef{} = ref}}) do
    case Registry.lookup(ref.registry, {ref.name, :server}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  defp stream(state, tools) do
    SkillKit.LLM.stream(state.messages,
      model: state.agent.model,
      system: state.agent.system_prompt,
      tools: tools
    )
  end

  defp new_accumulator do
    %{text: "", tool_calls: [], usage: %{input_tokens: 0, output_tokens: 0}}
  end

  defp process_event(%Delta{text: text}, acc, state) do
    notify_caller(state, %Delta{text: text, agent: state.agent.name})
    %{acc | text: acc.text <> text}
  end

  defp process_event(%ToolCallStart{} = event, acc, state) do
    notify_caller(state, %{event | agent: state.agent.name})
    acc
  end

  defp process_event(%ToolCallComplete{} = event, acc, state) do
    notify_caller(state, %{event | agent: state.agent.name})
    tool_call = %ToolCall{id: event.id, name: event.name, input: event.input}
    %{acc | tool_calls: acc.tool_calls ++ [tool_call]}
  end

  defp process_event(%Usage{} = usage, acc, _state) do
    merged = %{
      input_tokens: acc.usage.input_tokens + usage.input_tokens,
      output_tokens: acc.usage.output_tokens + usage.output_tokens
    }

    %{acc | usage: merged}
  end

  defp process_event(%Done{}, acc, _state), do: acc
  defp process_event(_other, acc, _state), do: acc

  defp finalize_response(acc) do
    content = if acc.text == "", do: nil, else: acc.text

    %AssistantMessage{
      content: content,
      tool_calls: acc.tool_calls
    }
  end

  defp notify_caller(%{agent: %{caller: nil}}, _event), do: :ok

  defp notify_caller(%{agent: %{caller: pid}}, event) do
    send(pid, event)
  end

  defp cast_to_mailbox(state, message) do
    case Registry.lookup(state.agent.registry, {state.agent.name, :mailbox}) do
      [{pid, _}] -> GenServer.cast(pid, message)
      [] -> :ok
    end
  end

  defp pop_by_monitor(subagents, ref) do
    case Enum.find(subagents, fn {_pid, entry} -> entry.monitor_ref == ref end) do
      nil -> nil
      {pid, entry} -> {entry, Map.delete(subagents, pid)}
    end
  end

  defp load_conversation(nil, _agent_name, _catalog), do: []

  defp load_conversation({mod, config}, agent_name, catalog) do
    load_context = %{agent_name: agent_name}

    try do
      catalog
      |> hooked_load(load_context, mod, agent_name, config)
      |> unwrap_load_result()
    catch
      :exit, _reason -> do_load_conversation(mod, agent_name, config)
    end
  end

  defp hooked_load(catalog, load_context, mod, agent_name, config) do
    Hooks.call(catalog, :conversation_load, load_context, fn ->
      messages = do_load_conversation(mod, agent_name, config)
      {messages, Map.put(load_context, :messages, messages)}
    end)
  end

  defp unwrap_load_result({:deny, _reason}), do: []
  defp unwrap_load_result(messages), do: messages

  defp do_load_conversation(mod, agent_name, config) do
    case apply(mod, :load, [agent_name, config]) do
      {:ok, msgs} -> msgs
      {:error, _} -> []
    end
  end

  defp save_conversation(%{agent: %{conversation_store: nil}}), do: :ok

  defp save_conversation(%{agent: %{conversation_store: {mod, config}}} = state) do
    save_context = %{
      agent_name: state.agent.name,
      message_count: length(state.messages)
    }

    Hooks.call(catalog(state.agent), :conversation_save, save_context, fn ->
      apply(mod, :save, [state.agent.name, state.messages, config])
      {:ok, save_context}
    end)
  end

  defp catalog(%SkillKit.Agent{} = agent) do
    {:via, Registry, {agent.registry, {agent.name, :catalog}}}
  end
end
