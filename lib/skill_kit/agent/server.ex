defmodule SkillKit.Agent.Server do
  @moduledoc """
  Core agent process. Drives the LLM loop, manages subagents.

  The loop runs synchronously within `handle_info({:mailbox_flush, ...})`.
  Streams from `SkillKit.LLM`, decodes responses, routes tool calls,
  and loops until no more tool calls are returned.
  """

  use GenServer

  alias SkillKit.Agent.Definition
  alias SkillKit.Agent.ToolRouter
  alias SkillKit.LLM.Anthropic.Decoder
  alias SkillKit.LLM.Message

  defstruct [
    :agent_name,
    :parent_name,
    :definition,
    :depth,
    :scope,
    :registry,
    :backend,
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
          backend: {module(), keyword()} | nil,
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

    backend = Keyword.get(opts, :backend)

    {:ok, %__MODULE__{
      agent_name: agent_name,
      parent_name: parent_name,
      definition: definition,
      depth: depth,
      scope: scope,
      registry: registry,
      backend: backend
    }}
  end

  # --- Agent Loop ---

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

    {:noreply, state}
  end

  # Subagent finished — inject result as System message via mailbox
  @impl true
  def handle_info({:subagent_result, pid, result}, state) do
    case Map.pop(state.subagents, pid) do
      {nil, _} ->
        {:noreply, state}

      {entry, subagents} ->
        state = %{state | subagents: subagents}

        message = %Message.System{
          content: "[Background task #{inspect(entry.task_ref)} complete] " <>
                   "Agent '#{entry.name}' returned: #{inspect(result)}"
        }

        :telemetry.execute(
          [:skill_kit, :agent, :subagent_result],
          %{},
          %{agent_name: state.agent_name, subagent_name: entry.name,
            task_ref: entry.task_ref, result: result}
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
          content: "[Background task #{inspect(entry.task_ref)} failed] " <>
                   "Agent '#{entry.name}' crashed: #{inspect(reason)}"
        }

        cast_to_mailbox(state, {:message, message})
        {:noreply, state}
    end
  end

  # --- Core Loop ---

  defp run_agent_loop(state, new_messages) do
    state = %{state | messages: state.messages ++ new_messages}

    llm_opts = build_llm_opts(state)
    {:ok, stream} = SkillKit.LLM.stream(state.messages, llm_opts)
    response = stream |> Enum.to_list() |> Decoder.decode_events()

    :telemetry.execute(
      [:skill_kit, :agent, :response],
      %{},
      %{agent_name: state.agent_name, response: response}
    )

    state = %{state | messages: state.messages ++ [response]}

    case response.tool_calls do
      [] ->
        state

      tool_calls ->
        classifier = fn _tc -> :local end
        local_handler = &execute_local_tool/1

        {results, state} = ToolRouter.execute(tool_calls, state, classifier, local_handler)

        Enum.each(tool_calls, fn tc ->
          :telemetry.execute(
            [:skill_kit, :agent, :tool_call],
            %{},
            %{agent_name: state.agent_name, tool_call: tc}
          )
        end)

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
  end

  defp execute_local_tool(%Message.ToolCall{id: id, name: name, input: input}) do
    %Message.ToolResult{
      tool_call_id: id,
      content: "Tool '#{name}' executed with input: #{inspect(input)}"
    }
  end

  defp build_llm_opts(state) do
    opts = [model: state.definition.model]
    if state.backend, do: Keyword.put(opts, :backend, state.backend), else: opts
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
end
