defmodule SkillKit.Agent.Server do
  @moduledoc """
  Core agent process. Drives the LLM loop and manages agent lifecycle.

  Tool execution is delegated to `SkillKit.Agent.ToolDispatch`. The Server
  handles message flow, LLM streaming, conversation persistence, and
  subagent lifecycle via `:DOWN` monitoring.

  The loop runs synchronously within `handle_info({:mailbox_flush, ...})`.
  Tool calls — including suspended ones — are fully resolved by ToolRunner
  before the Server continues the loop.
  """

  use GenServer

  alias SkillKit.Agent.StreamAccumulator
  alias SkillKit.Agent.SubLoop
  alias SkillKit.Agent.ToolRunner
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.Event.Usage
  alias SkillKit.Hooks
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.SystemMessage
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.UserMessage

  defstruct [
    :agent,
    halted: false,
    messages: [],
    subagents: %{}
  ]

  @type t :: %__MODULE__{
          agent: SkillKit.Agent.t(),
          halted: boolean(),
          messages: list(),
          subagents: map()
        }

  def start_link(%SkillKit.Agent{} = agent) do
    GenServer.start_link(__MODULE__, agent)
  end

  @impl true
  def init(%SkillKit.Agent{} = agent) do
    Registry.register(agent.registry, {agent.name, :server}, [])

    stored = load_conversation(agent.conversation_store, agent.name, agent)
    messages = agent.initial_messages ++ stored

    state = %__MODULE__{
      agent: agent,
      messages: messages,
      halted: false
    }

    Hooks.cast(agent, :pre_agent, %{
      agent_name: agent.name,
      definition: agent
    })

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    Hooks.cast(state.agent, :post_agent, %{
      agent_name: state.agent.name,
      definition: state.agent
    })

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
      Hooks.call(state.agent, :turn, turn_context, fn ->
        updated = run_agent_loop(state, new_messages)
        {updated, turn_context}
      end)

    save_conversation(state)

    {:noreply, state}
  end

  # Subagent completed naturally — capture result from shutdown reason
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, {:shutdown, {:result, response}}}, state) do
    case Map.pop(state.subagents, pid) do
      {nil, _} ->
        {:noreply, state}

      {entry, subagents} ->
        state = %{state | subagents: subagents}

        intent = entry.parent_intent || "N/A"
        result_text = response.content || "(no content)"

        message = %SystemMessage{
          content: """
          [Subagent Complete] #{entry.name} finished the task you delegated.

          **Your plan before delegating:** "#{intent}"
          **Task you delegated:** "#{entry.task}"
          **Result:**
          #{result_text}

          Continue with your plan.\
          """
        }

        Hooks.cast(state.agent, :post_subagent, %{
          name: entry.name,
          task: entry.task,
          result: result_text,
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

        require Logger

        Logger.warning(
          "Subagent crashed: name=#{entry.name} task=#{entry.task} reason=#{inspect(reason, pretty: true, limit: :infinity)}"
        )

        message = %SystemMessage{
          content:
            "[Subagent Failed] #{entry.name} crashed while working on: #{entry.task}\n" <>
              "Reason: #{inspect(reason)}"
        }

        cast_to_mailbox(state, {:message, message})
        {:noreply, state}
    end
  end

  # --- Event processing (send_event/3 entry point) ---

  @impl true
  def handle_cast({:process_event, _content, _opts}, %{halted: true} = state) do
    {:noreply, state}
  end

  def handle_cast({:process_event, content, opts}, state) do
    config = build_event_config(state, content, opts)
    result_text = SubLoop.run(state, config)

    # Bubble the sub-loop's result up to the main agent as a SystemMessage
    # so the main agent runs a turn on it and can surface the outcome or
    # react naturally in the primary conversation. Sub-loop intermediate
    # steps (tool calls, reasoning) still stay inside the sub-loop — only
    # the final text crosses back into the main thread.
    bubble_event_result(state, result_text, config)

    {:noreply, state}
  end

  defp bubble_event_result(state, result_text, config) do
    content = format_event_bubble(config.sub_name, result_text)
    cast_to_mailbox(state, {:message, %SystemMessage{content: content}})
  end

  defp format_event_bubble(sub_name, result_text) do
    "[Event delivered — #{sub_name}]\n\n" <>
      result_text <>
      "\n\nThe event has been handled. Surface the outcome to the user in a brief sentence or two, " <>
      "or silently acknowledge if the handler's output indicated a quiet log-only intent."
  end

  defp build_event_config(state, content, opts) do
    %{
      system_append: Keyword.fetch!(opts, :system_append),
      initial_messages: resolve_initial_history(opts, state) ++ [%UserMessage{content: content}],
      sub_tools: build_event_sub_tools(state, opts),
      sub_name: Keyword.fetch!(opts, :sub_agent_name),
      error_prefix: Keyword.get(opts, :error_prefix, "Event error")
    }
  end

  defp resolve_initial_history(opts, state) do
    case Keyword.get(opts, :initial_messages, :empty) do
      :empty -> []
      :forked -> fork_parent_messages(state.messages)
      list when is_list(list) -> list
    end
  end

  # Drop a trailing assistant message that carries dangling tool_calls — same
  # reasoning as SkillActivation.fork_messages/1.
  defp fork_parent_messages(messages) do
    case List.last(messages) do
      %AssistantMessage{tool_calls: [_ | _]} -> Enum.drop(messages, -1)
      _ -> messages
    end
  end

  defp build_event_sub_tools(state, opts) do
    tools_remove = Keyword.get(opts, :tools_remove, [])
    tools_add = Keyword.get(opts, :tools_add, [])

    send_message_tool =
      {SkillKit.Tools.SendMessage, %{target: SkillKit.AgentRef.from_agent(state.agent)}}

    state.agent.tools
    |> Enum.reject(fn {module, _kit_opts} -> module in tools_remove end)
    |> Enum.map(&resolve_parent_tool(&1, state))
    |> Kernel.++(Enum.map(tools_add, &resolve_added_tool(&1, state)))
    |> Kernel.++([resolve_added_tool(send_message_tool, state)])
  end

  defp resolve_parent_tool({module, _kit_opts}, state) do
    definition = module.definition()
    context = parent_tool_context(state.agent, definition.name)
    {module, context, definition}
  end

  defp resolve_added_tool({module, context}, state) do
    definition = module.definition()
    merged = Map.merge(base_context(state.agent), context)
    {module, merged, definition}
  end

  defp parent_tool_context(agent, tool_name) do
    base = base_context(agent)

    case SkillKit.Catalog.tool_config(agent, tool_name) do
      nil -> base
      {_tool, metadata} -> Map.merge(base, Map.delete(metadata, :tool))
    end
  end

  defp base_context(agent) do
    %{
      agent: agent,
      agent_name: root_agent_name(agent),
      scope: agent.scope
    }
  end

  defp root_agent_name(%{parent_ref: %SkillKit.AgentRef{name: name}}), do: name
  defp root_agent_name(%{name: name}), do: name

  # --- Core Loop ---

  defp run_agent_loop(%{halted: true} = state, _new_messages), do: state

  defp run_agent_loop(state, new_messages) do
    state = %{state | messages: state.messages ++ new_messages}

    tools = SkillKit.Catalog.tool_definitions(state.agent)

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
        acc = Enum.reduce(event_stream, StreamAccumulator.new(), &process_event(&1, &2, state))
        response = StreamAccumulator.finalize(acc)
        state = %{state | messages: state.messages ++ [response]}
        handle_response(response, state)

      {:error, reason} ->
        notify_caller(state, %EventError{agent: state.agent.name, reason: reason})
        state
    end
  end

  defp hooked_llm_request(state, tools, llm_context) do
    Hooks.call(state.agent, :llm_request, llm_context, fn ->
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
    complete_turn(response, state)
  end

  defp handle_response(%AssistantMessage{tool_calls: tool_calls}, state) do
    {results, state} = ToolRunner.execute_all(state, tool_calls)
    state = %{state | messages: state.messages ++ results}
    run_agent_loop(state, [])
  end

  defp complete_turn(_response, %{agent: %{parent_ref: nil}} = state), do: state

  defp complete_turn(response, state) do
    save_conversation(state)
    exit({:shutdown, {:result, response}})
  end

  # --- Streaming ---

  defp stream(state, tools) do
    SkillKit.LLM.stream(state.messages,
      model: state.agent.model,
      system: state.agent.system_prompt,
      tools: tools
    )
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

  # --- Helpers ---

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

  # --- Conversation Persistence ---

  defp load_conversation(nil, _agent_name, _agent), do: []

  defp load_conversation({mod, config}, agent_name, agent) do
    load_context = %{agent_name: agent_name}

    Hooks.call(agent, :conversation_load, load_context, fn ->
      messages = load_from_store(mod, agent_name, config)
      {messages, Map.put(load_context, :messages, messages)}
    end)
    |> unwrap_denied()
  end

  defp load_from_store(mod, agent_name, config) do
    case apply(mod, :load, [agent_name, config]) do
      {:ok, msgs} -> msgs
      {:error, _} -> []
    end
  end

  defp unwrap_denied({:deny, _}), do: []
  defp unwrap_denied(result), do: result

  defp save_conversation(%{agent: %{conversation_store: nil}}), do: :ok

  defp save_conversation(%{agent: %{conversation_store: {mod, config}}} = state) do
    save_context = %{
      agent_name: state.agent.name,
      message_count: length(state.messages)
    }

    Hooks.call(state.agent, :conversation_save, save_context, fn ->
      apply(mod, :save, [state.agent.name, state.messages, config])
      {:ok, save_context}
    end)
  end
end
