defmodule SkillKit.Agent.SubLoop do
  @moduledoc false

  # Private primitive: runs an in-process LLM loop with a scoped system
  # prompt, a resolved tool list, and event forwarding to the parent's
  # caller tagged with a synthetic sub-agent name.
  #
  # Used by:
  #   * `SkillKit.Agent.SkillActivation` — nested skill calls driven by
  #     the LLM's `activate_skill` tool use
  #   * `SkillKit.send_event/3` — webhook deliveries and other event
  #     triggers that want isolated processing with a scoped tool set
  #     and no pollution of the parent's message history
  #
  # Callers prepare the scope (sub_tools, initial_messages, system_append,
  # sub_name, error_prefix) and this module runs the LLM + tool-dispatch
  # loop until a final assistant message with no tool calls. Returns the
  # final text (or an error string prefixed with `error_prefix`).

  alias SkillKit.Agent.Server
  alias SkillKit.Agent.SkillActivation
  alias SkillKit.Agent.StreamAccumulator
  alias SkillKit.Agent.ToolDispatch
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.Event.Usage
  alias SkillKit.LLM
  alias SkillKit.ToolExecution
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.ToolResult

  @type sub_tool :: {module(), map(), SkillKit.Tool.t()}

  @type config :: %{
          required(:system_append) => String.t(),
          required(:initial_messages) => [term()],
          required(:sub_tools) => [sub_tool()],
          required(:sub_name) => String.t(),
          required(:error_prefix) => String.t(),
          optional(:model) => String.t() | nil
        }

  @spec run(Server.t(), config()) :: String.t()
  def run(%Server{} = parent_state, config) do
    system = parent_state.agent.system_prompt <> "\n\n" <> config.system_append
    tool_defs = Enum.map(config.sub_tools, fn {_m, _c, def} -> def end)
    loop(parent_state, config, system, config.initial_messages, tool_defs)
  end

  # -- main loop -----------------------------------------------------------

  defp loop(parent_state, config, system, messages, tool_defs) do
    dispatch_stream(
      LLM.stream(messages,
        model: Map.get(config, :model, parent_state.agent.model),
        system: system,
        tools: tool_defs
      ),
      parent_state,
      config,
      system,
      messages,
      tool_defs
    )
  end

  defp dispatch_stream({:ok, stream}, parent_state, config, system, messages, tool_defs) do
    response = consume_stream(stream, parent_state.agent, config.sub_name)
    handle_response(response, parent_state, config, system, messages, tool_defs)
  end

  defp dispatch_stream({:error, reason}, _parent, config, _sys, _msgs, _td) do
    "#{config.error_prefix}: #{inspect(reason)}"
  end

  defp handle_response(%AssistantMessage{tool_calls: []} = response, _p, _c, _sys, _m, _td) do
    response.content || ""
  end

  defp handle_response(
         %AssistantMessage{tool_calls: tool_calls} = response,
         parent_state,
         config,
         system,
         messages,
         tool_defs
       ) do
    messages = messages ++ [response]
    results = Enum.map(tool_calls, &execute_tool_call(&1, parent_state, config))
    messages = messages ++ results
    loop(parent_state, config, system, messages, tool_defs)
  end

  # -- stream consumption --------------------------------------------------

  defp consume_stream(stream, agent, sub_name) do
    acc =
      Enum.reduce(stream, StreamAccumulator.new(), &process_event(&1, &2, agent, sub_name))

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

  defp process_event(%Usage{} = usage, acc, agent, sub_name) do
    notify_caller(agent, %{usage | agent: sub_name})
    %{acc | usage: StreamAccumulator.merge_usage(acc.usage, usage)}
  end

  defp process_event(%Done{}, acc, _agent, _sub_name), do: acc
  defp process_event(_other, acc, _agent, _sub_name), do: acc

  # -- tool routing & execution -------------------------------------------

  defp execute_tool_call(
         %ToolCall{id: id, name: name, input: input},
         parent_state,
         config
       ) do
    result = run_tool(find_tool(config.sub_tools, name), id, name, input, parent_state)
    notify_caller(parent_state.agent, %{result | agent: config.sub_name})
    result
  end

  defp find_tool(sub_tools, name) do
    Enum.find(sub_tools, fn {_m, _c, def} -> def.name == name end)
  end

  defp run_tool(nil, id, name, _input, _parent_state) do
    %ToolResult{tool_call_id: id, content: "Unknown tool: #{name}", is_error: true}
  end

  defp run_tool({SkillActivation, _ctx, _def}, id, _name, input, parent_state) do
    SkillActivation.dispatch(parent_state, id, input)
  end

  defp run_tool({module, context, _def}, id, _name, input, _parent_state) do
    exec = %ToolExecution{tool: module, input: input, context: context}
    to_result(ToolExecution.execute(exec), id)
  end

  defp to_result({:ok, execution}, id) do
    %ToolResult{tool_call_id: id, content: ToolDispatch.extract_output(execution.result)}
  end

  defp to_result({:error, execution}, id) do
    %ToolResult{tool_call_id: id, content: ToolDispatch.extract_error(execution), is_error: true}
  end

  defp to_result({:pending, _execution}, id) do
    %ToolResult{
      tool_call_id: id,
      content: "Tool suspension is not supported in sub-loops",
      is_error: true
    }
  end

  # -- notifications -------------------------------------------------------

  defp notify_caller(%{caller: nil}, _event), do: :ok
  defp notify_caller(%{caller: pid}, event), do: send(pid, event)
end
