defmodule SkillKit.Agent.Server do
  @moduledoc """
  Core agent process. Drives the LLM loop, manages subagents.

  The loop runs synchronously within `handle_info({:mailbox_flush, ...})`.
  Streams from `SkillKit.LLM`, decodes responses, routes tool calls,
  and loops until no more tool calls are returned.
  """

  use GenServer

  alias SkillKit.Agent.Definition
  alias SkillKit.Agent.ToolBuilder
  alias SkillKit.LLM.Anthropic.Decoder
  alias SkillKit.LLM.Message

  defstruct [
    :agent_name,
    :parent_name,
    :definition,
    :depth,
    :scope,
    :registry,
    :provider,
    :caller,
    :kits,
    :parent_registry,
    :sources,
    :conversation_store,
    halted: false,
    messages: [],
    subagents: %{},
    pending_requests: %{}
  ]

  @type t :: %__MODULE__{
          agent_name: String.t(),
          parent_name: String.t() | nil,
          definition: Definition.t(),
          depth: non_neg_integer(),
          scope: term(),
          registry: atom(),
          provider: {module(), keyword()} | nil,
          caller: pid() | nil,
          kits: list(),
          parent_registry: atom() | nil,
          sources: list(),
          conversation_store: {module(), keyword()} | nil,
          halted: boolean(),
          messages: list(),
          subagents: map(),
          pending_requests: map()
        }

  def start_link({agent_name, definition, depth, parent_name, scope, registry}) do
    start_link({agent_name, definition, depth, parent_name, scope, registry, []})
  end

  def start_link({agent_name, definition, depth, parent_name, scope, registry, opts}) do
    GenServer.start_link(__MODULE__, {agent_name, definition, depth, parent_name, scope, registry, opts})
  end

  @impl true
  def init({agent_name, definition, depth, parent_name, scope, registry, opts}) do
    Registry.register(registry, {agent_name, :server}, [])

    provider = Keyword.get(opts, :provider)
    caller = Keyword.get(opts, :caller)
    kits = Keyword.get(opts, :kits, [])
    parent_registry = Keyword.get(opts, :parent_registry)
    sources = Keyword.get(opts, :sources, [])
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

    {:ok, %__MODULE__{
      agent_name: agent_name,
      parent_name: parent_name,
      definition: definition,
      depth: depth,
      scope: scope,
      registry: registry,
      provider: provider,
      caller: caller,
      kits: kits,
      parent_registry: parent_registry,
      sources: sources,
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
    :telemetry.execute(
      [:skill_kit, :agent, :turn_start],
      %{},
      %{agent_name: state.agent_name, message_count: length(new_messages)}
    )

    start_time = System.monotonic_time()
    state = run_agent_loop(state, new_messages)

    duration = System.monotonic_time() - start_time
    :telemetry.execute(
      [:skill_kit, :agent, :turn_end],
      %{duration: duration},
      %{agent_name: state.agent_name}
    )

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

        message = %Message.System{
          content: """
          [Subagent Complete] #{entry.name} finished the task you delegated.

          **Your plan before delegating:** "#{intent}"
          **Task you delegated:** "#{entry.task}"
          **Result:**
          #{result}

          Continue with your plan.\
          """
        }

        :telemetry.execute(
          [:skill_kit, :agent, :subagent_result],
          %{},
          %{agent_name: state.agent_name, subagent_name: entry.name,
            task: entry.task, result: result}
        )

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

        message = %Message.System{
          content: "[Subagent Failed] #{entry.name} crashed while working on: #{entry.task}\n" <>
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

    tools = ToolBuilder.build_tools(state.kits, subagent: state.depth > 0)

    llm_opts =
      [
        model: state.definition.model,
        max_tokens: state.definition.max_tokens,
        system: state.definition.system_prompt,
        tools: tools
      ]

    llm_opts =
      if state.provider, do: Keyword.put(llm_opts, :provider, state.provider), else: llm_opts

    case SkillKit.LLM.stream(state.messages, llm_opts) do
      {:ok, stream} ->
        acc = Enum.reduce(stream, Decoder.new_accumulator(), &stream_event(&1, &2, state))

        response = Decoder.finalize(acc)

        :telemetry.execute(
          [:skill_kit, :agent, :usage],
          acc.usage,
          %{agent_name: state.agent_name}
        )

        :telemetry.execute(
          [:skill_kit, :agent, :response],
          %{},
          %{agent_name: state.agent_name, response: response}
        )

        state = %{state | messages: state.messages ++ [response]}

        handle_response(response, state)

      {:error, reason} ->
        :telemetry.execute(
          [:skill_kit, :agent, :error],
          %{},
          %{agent_name: state.agent_name, error: reason}
        )

        notify_caller(state, {:error, reason})
        state
    end
  end

  defp handle_response(%{tool_calls: []} = response, state) do
    notify_caller(state, {:response, response.content})
    state
  end

  defp handle_response(%{tool_calls: tool_calls} = _response, state) do
    classifier = ToolBuilder.classifier(state.kits)
    {results, state} = execute_tool_calls(tool_calls, state, classifier)

    Enum.each(results, fn result ->
      :telemetry.execute(
        [:skill_kit, :agent, :tool_result],
        %{},
        %{agent_name: state.agent_name, tool_call_id: result.tool_call_id, result: result}
      )
    end)

    state = %{state | messages: state.messages ++ results}
    run_agent_loop(state, [])
  end

  defp execute_tool_calls(tool_calls, state, classifier) do
    Enum.map_reduce(tool_calls, state, fn tc, acc ->
      :telemetry.execute(
        [:skill_kit, :agent, :tool_call],
        %{},
        %{agent_name: acc.agent_name, tool_call: tc}
      )

      notify_caller(acc, {:tool_call, tc.name, tc.input})

      {result, acc} =
        case classifier.(tc) do
          :executor -> {execute_command(tc, acc), acc}
          :activate_skill -> {activate_skill(tc, acc), acc}
          :subagent -> spawn_subagent(tc, acc)
          :builtin -> handle_builtin(tc, acc)
        end

      notify_caller(acc, {:tool_result, tc.name, result.content, result.is_error})

      {result, acc}
    end)
  end

  defp execute_command(%Message.ToolCall{id: id, input: input}, state) do
    command = Map.get(input, "command", "")
    context = %{cwd: state.definition.workspace, scope: state.scope}
    skill_registry = {:via, Registry, {state.registry, {state.agent_name, :skill_registry}}}

    case SkillKit.Executor.run(skill_registry, command, context) do
      {:ok, execution} -> %Message.ToolResult{tool_call_id: id, content: execution.results["execute"] |> extract_output()}
      {:error, execution} -> %Message.ToolResult{tool_call_id: id, content: extract_error(execution), is_error: true}
      {:pending, _execution} -> %Message.ToolResult{tool_call_id: id, content: "Command requires approval (not yet supported).", is_error: true}
    end
  end

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

  defp activate_skill(%Message.ToolCall{id: id, input: input}, state) do
    skill_name = Map.get(input, "name", "")
    skill_registry = {:via, Registry, {state.registry, {state.agent_name, :skill_registry}}}

    opts = if state.scope, do: [scopes: state.scope], else: []

    case SkillKit.Catalog.activate(skill_registry, skill_name, %{}, opts) do
      {:ok, rendered_body} ->
        %Message.ToolResult{tool_call_id: id, content: rendered_body}

      {:error, :unauthorized} ->
        %Message.ToolResult{
          tool_call_id: id,
          content: "Unauthorized: insufficient scope for skill #{skill_name}",
          is_error: true
        }

      {:error, reason} ->
        %Message.ToolResult{tool_call_id: id, content: "Error: #{inspect(reason)}", is_error: true}
    end
  end

  defp spawn_subagent(%Message.ToolCall{id: id, name: name, input: input}, state) do
    task = Map.get(input, "task", "")

    if state.depth >= state.definition.max_agent_depth do
      result = %Message.ToolResult{
        tool_call_id: id,
        content: "Cannot spawn subagent: max depth (#{state.definition.max_agent_depth}) reached.",
        is_error: true
      }
      {result, state}
    else
      case find_agent_definition(name, state.kits) do
        nil ->
          result = %Message.ToolResult{
            tool_call_id: id,
            content: "Unknown agent: #{name}",
            is_error: true
          }
          {result, state}

        agent_def ->
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

    spawn_opts = [sources: state.sources]
    spawn_opts = if state.provider, do: Keyword.put(spawn_opts, :provider, state.provider), else: spawn_opts

    case SkillKit.start_subagent(overridden_def, parent_opts, spawn_opts) do
      {:ok, agent_ref} ->
        [{server_pid, _}] = Registry.lookup(agent_ref.registry, {subagent_name, :server})
        monitor_ref = Process.monitor(server_pid)

        parent_intent = get_last_assistant_content(state.messages)

        subagents = Map.put(state.subagents, server_pid, %{
          name: name,
          task: task,
          monitor_ref: monitor_ref,
          parent_intent: parent_intent,
          agent_ref: agent_ref
        })

        state = %{state | subagents: subagents}

        SkillKit.send_message(agent_ref, task)

        result = %Message.ToolResult{
          tool_call_id: id,
          content: "Delegated to #{name}. You will receive the result when it completes."
        }
        {result, state}

      {:error, reason} ->
        result = %Message.ToolResult{
          tool_call_id: id,
          content: "Failed to start subagent #{name}: #{inspect(reason)}",
          is_error: true
        }
        {result, state}
    end
  end

  defp find_agent_definition(name, kits) do
    kits
    |> Enum.flat_map(& &1.agents)
    |> Enum.find(& &1.name == name)
  end

  defp get_last_assistant_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message.Assistant{content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp handle_builtin(%Message.ToolCall{id: id, name: "report_result", input: input}, state) do
    result = Map.get(input, "result", "")

    case lookup_parent(state) do
      {:ok, parent_pid} ->
        send(parent_pid, {:subagent_result, self(), result})

      :not_found ->
        :telemetry.execute(
          [:skill_kit, :agent, :orphaned_result],
          %{},
          %{agent_name: state.agent_name, parent_name: state.parent_name, result: result}
        )
    end

    state = %{state | halted: true}
    {%Message.ToolResult{tool_call_id: id, content: "Result reported successfully."}, state}
  end

  defp handle_builtin(%Message.ToolCall{id: id, name: "report_status"}, state) do
    {%Message.ToolResult{tool_call_id: id, content: "Status acknowledged."}, state}
  end

  defp handle_builtin(%Message.ToolCall{id: id, name: name}, state) do
    {%Message.ToolResult{tool_call_id: id, content: "Unknown builtin: #{name}", is_error: true}, state}
  end

  defp lookup_parent(%{parent_registry: nil}), do: :not_found
  defp lookup_parent(%{parent_registry: _reg, parent_name: nil}), do: :not_found

  defp lookup_parent(%{parent_registry: reg, parent_name: name}) do
    case Registry.lookup(reg, {name, :server}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  defp stream_event(event, acc, state) do
    {action, acc} = Decoder.decode_event(event, acc)

    case action do
      {:delta, text} -> notify_caller(state, {:delta, text})
      :none -> :ok
    end

    acc
  end

  defp notify_caller(%{caller: nil}, _event), do: :ok

  defp notify_caller(%{caller: pid, agent_name: name}, event) do
    send(pid, {:skill_kit, name, event})
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
end
