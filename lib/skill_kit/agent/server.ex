defmodule SkillKit.Agent.Server do
  @moduledoc """
  Core agent process. Drives the LLM loop, manages subagents.

  The loop runs synchronously within `handle_info({:mailbox_flush, ...})`.
  Streams from `SkillKit.LLM`, decodes responses, routes tool calls,
  and loops until no more tool calls are returned.
  """

  use GenServer

  alias SkillKit.Agent.Definition
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.Event.Usage
  alias SkillKit.Skill
  alias SkillKit.Telemetry
  alias SkillKit.ToolExecution
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.SystemMessage
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.ToolResult

  defstruct [
    :agent_name,
    :parent_name,
    :definition,
    :depth,
    :scope,
    :registry,
    :caller,
    :parent_registry,
    :skills,
    :conversation_store,
    halted: false,
    messages: [],
    subagents: %{},
    pending_requests: %{},
    activated_skills: []
  ]

  @type t :: %__MODULE__{
          agent_name: String.t(),
          parent_name: String.t() | nil,
          definition: Definition.t(),
          depth: non_neg_integer(),
          scope: term(),
          registry: atom(),
          caller: pid() | nil,
          parent_registry: atom() | nil,
          skills: list(),
          conversation_store: {module(), keyword()} | nil,
          halted: boolean(),
          messages: list(),
          subagents: map(),
          pending_requests: map(),
          activated_skills: [SkillKit.Skill.t()]
        }

  def start_link({agent_name, definition, depth, parent_name, scope, registry}) do
    start_link({agent_name, definition, depth, parent_name, scope, registry, []})
  end

  def start_link({agent_name, definition, depth, parent_name, scope, registry, opts}) do
    GenServer.start_link(
      __MODULE__,
      {agent_name, definition, depth, parent_name, scope, registry, opts}
    )
  end

  @impl true
  def init({agent_name, definition, depth, parent_name, scope, registry, opts}) do
    Registry.register(registry, {agent_name, :server}, [])

    caller = Keyword.get(opts, :caller)
    parent_registry = Keyword.get(opts, :parent_registry)
    skills = Keyword.get(opts, :skills, [])
    conversation_store = Keyword.get(opts, :conversation_store)

    messages =
      case conversation_store do
        {mod, config} ->
          case mod.load(agent_name, config) do
            {:ok, msgs} -> msgs
            {:error, _} -> []
          end

        nil ->
          []
      end

    {:ok,
     %__MODULE__{
       agent_name: agent_name,
       parent_name: parent_name,
       definition: definition,
       depth: depth,
       scope: scope,
       registry: registry,
       caller: caller,
       parent_registry: parent_registry,
       skills: skills,
       conversation_store: conversation_store,
       messages: messages,
       halted: false
     }}
  end

  # --- Agent Loop ---

  @impl true
  def handle_info({:mailbox_flush, _new_messages}, %{halted: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:mailbox_flush, new_messages}, state) do
    start_time =
      Telemetry.start(
        [:agent, :turn],
        %{agent_name: state.agent_name, message_count: length(new_messages)}
      )

    state = run_agent_loop(state, new_messages)

    Telemetry.stop([:agent, :turn], start_time, %{agent_name: state.agent_name})

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

        Telemetry.event([:agent, :subagent_result], %{}, %{
          agent_name: state.agent_name,
          subagent_name: entry.name,
          task: entry.task,
          result: result
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
      SkillKit.Catalog.tool_definitions(catalog(state),
        subagent: state.depth > 0,
        activated_skills: state.activated_skills
      )

    case stream(state, tools) do
      {:ok, event_stream} ->
        acc = Enum.reduce(event_stream, new_accumulator(), &process_event(&1, &2, state))

        response = finalize_response(acc)

        Telemetry.event([:agent, :usage], acc.usage, %{agent_name: state.agent_name})

        Telemetry.event([:agent, :response], %{}, %{
          agent_name: state.agent_name,
          response: response
        })

        state = %{state | messages: state.messages ++ [response]}

        handle_response(response, state)

      {:error, reason} ->
        Telemetry.event([:agent, :error], %{}, %{agent_name: state.agent_name, error: reason})

        notify_caller(state, %EventError{agent: state.agent_name, reason: reason})
        state
    end
  end

  defp handle_response(%AssistantMessage{tool_calls: []} = response, state) do
    notify_caller(state, %{response | agent: state.agent_name})
    state
  end

  defp handle_response(%AssistantMessage{tool_calls: tool_calls}, state) do
    {results, state} = execute_tool_calls(tool_calls, state)

    Enum.each(results, fn result ->
      Telemetry.event([:agent, :tool_result], %{}, %{
        agent_name: state.agent_name,
        tool_call_id: result.tool_call_id,
        result: result
      })
    end)

    state = %{state | messages: state.messages ++ results}
    run_agent_loop(state, [])
  end

  defp execute_tool_calls(tool_calls, state) do
    Enum.map_reduce(tool_calls, state, fn tc, acc ->
      Telemetry.event([:agent, :tool_call], %{}, %{agent_name: acc.agent_name, tool_call: tc})

      {result, acc} =
        case SkillKit.Catalog.classify(catalog(acc), tc.name, acc.activated_skills) do
          :tool -> {execute_command(tc, acc), acc}
          {:module_skill, skill} -> {execute_module_skill(tc, skill, acc), acc}
          :activate_skill -> activate_skill(tc, acc)
          :subagent -> spawn_subagent(tc, acc)
          :builtin -> handle_builtin(tc, acc)
        end

      notify_caller(acc, %{result | agent: acc.agent_name})

      {result, acc}
    end)
  end

  defp execute_command(%ToolCall{id: id, input: input}, state) do
    tool = find_tool(state)
    context = build_tool_context(state)

    case ToolExecution.start(tool, catalog(state), input, context) do
      {:ok, execution} ->
        %ToolResult{
          tool_call_id: id,
          content: extract_output(execution.results["execute"])
        }

      {:error, execution} ->
        %ToolResult{tool_call_id: id, content: extract_error(execution), is_error: true}

      {:pending, _execution} ->
        %ToolResult{
          tool_call_id: id,
          content: "Command requires approval (not yet supported).",
          is_error: true
        }
    end
  end

  defp find_tool(state) do
    case SkillKit.Catalog.tool_config(catalog(state)) do
      nil -> SkillKit.Tools.Shell
      {tool, _metadata} -> tool
    end
  end

  defp build_tool_context(state) do
    base_context = %{scope: state.scope}

    case SkillKit.Catalog.tool_config(catalog(state)) do
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
    case execution.results["execute"] do
      {:error, {output, _code}} -> ensure_non_empty(output)
      {:error, reason} -> inspect(reason)
      _ -> "Execution failed"
    end
  end

  defp ensure_non_empty(""), do: "(no output)"
  defp ensure_non_empty(str) when is_binary(str), do: str
  defp ensure_non_empty(nil), do: "(no output)"

  defp activate_skill(%ToolCall{id: id, input: input}, state) do
    skill_name = Map.get(input, "name", "")
    arguments = Map.get(input, "arguments", "")

    case SkillKit.Catalog.get_skill(catalog(state), skill_name) do
      {:ok, skill} ->
        scope_context = %{agent: state.agent_name, skill: skill_name}
        render_and_activate(id, skill, arguments, state, scope_context)

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

  defp render_and_activate(id, skill, arguments, state, scope_context) do
    rendered = Skill.render(skill, %{"arguments" => arguments}, state.scope, scope_context)
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
    source_config = Map.get(skill.metadata, "source_config", [])

    context =
      %{scope: state.scope, agent_name: state.agent_name}
      |> Map.merge(Map.new(source_config))

    execution = %ToolExecution{skill: skill, input: input, context: context}

    case skill.tool.execute(execution) do
      {:ok, result} ->
        %ToolResult{tool_call_id: id, content: to_string(result)}

      {:error, reason} ->
        %ToolResult{tool_call_id: id, content: inspect(reason), is_error: true}
    end
  end

  defp spawn_subagent(%ToolCall{id: id, name: name, input: input}, state) do
    task = Map.get(input, "task", "")

    if state.depth >= state.definition.max_agent_depth do
      result = %ToolResult{
        tool_call_id: id,
        content:
          "Cannot spawn subagent: max depth (#{state.definition.max_agent_depth}) reached.",
        is_error: true
      }

      {result, state}
    else
      case SkillKit.Catalog.get_agent(catalog(state), name) do
        {:error, :not_found} ->
          result = %ToolResult{
            tool_call_id: id,
            content: "Unknown agent: #{name}",
            is_error: true
          }

          {result, state}

        {:ok, agent_def} ->
          do_spawn_subagent(id, name, task, agent_def, state)
      end
    end
  end

  defp do_spawn_subagent(id, name, task, agent_def, state) do
    subagent_name = "#{state.agent_name}/#{name}-#{:erlang.unique_integer([:positive])}"
    overridden_def = %{agent_def | name: subagent_name}

    parent_opts = [
      depth: state.depth,
      parent_name: state.agent_name,
      parent_registry: state.registry
    ]

    spawn_opts = [skills: state.skills]

    case SkillKit.start_subagent(overridden_def, parent_opts, spawn_opts) do
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

        state = %{state | subagents: subagents}

        SkillKit.send_message(agent_ref, task)

        result = %ToolResult{
          tool_call_id: id,
          content: "Delegated to #{name}. You will receive the result when it completes."
        }

        {result, state}

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
          agent_name: state.agent_name,
          parent_name: state.parent_name,
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

  defp lookup_parent(%{parent_registry: nil}), do: :not_found
  defp lookup_parent(%{parent_registry: _reg, parent_name: nil}), do: :not_found

  defp lookup_parent(%{parent_registry: reg, parent_name: name}) do
    case Registry.lookup(reg, {name, :server}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  defp stream(state, tools) do
    SkillKit.LLM.stream(state.messages,
      model: state.definition.model,
      system: state.definition.system_prompt,
      tools: tools
    )
  end

  defp new_accumulator do
    %{text: "", tool_calls: [], usage: %{input_tokens: 0, output_tokens: 0}}
  end

  defp process_event(%Delta{text: text}, acc, state) do
    notify_caller(state, %Delta{text: text, agent: state.agent_name})
    %{acc | text: acc.text <> text}
  end

  defp process_event(%ToolCallStart{} = event, acc, state) do
    notify_caller(state, %{event | agent: state.agent_name})
    acc
  end

  defp process_event(%ToolCallComplete{} = event, acc, state) do
    notify_caller(state, %{event | agent: state.agent_name})
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

  defp notify_caller(%{caller: nil}, _event), do: :ok

  defp notify_caller(%{caller: pid}, event) do
    send(pid, event)
  end

  defp cast_to_mailbox(state, message) do
    case Registry.lookup(state.registry, {state.agent_name, :mailbox}) do
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

  defp save_conversation(%{conversation_store: nil}), do: :ok

  defp save_conversation(%{conversation_store: {mod, config}, agent_name: id, messages: msgs}) do
    mod.save(id, msgs, config)
  end

  defp catalog(state) do
    {:via, Registry, {state.registry, {state.agent_name, :catalog}}}
  end
end
