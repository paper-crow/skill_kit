defmodule SkillKit.Agent.ToolRouter do
  @moduledoc """
  Classifies and executes tool calls from the LLM response.

  Takes a list of tool calls and routes each to either:
  - A local handler (executes inline, returns result immediately)
  - A subagent spawner (async delegation, returns immediate acknowledgment)

  Classification and execution are injected as functions — the router
  doesn't know about specific tools. This keeps it testable and
  decoupled from the skill registry and agent definition registry.
  """

  alias SkillKit.LLM.Message

  @type classifier :: (Message.ToolCall.t() -> :local | :subagent)
  @type local_handler :: (Message.ToolCall.t() -> Message.ToolResult.t())
  @type spawner :: (Message.ToolCall.t(), map() -> {Message.ToolResult.t(), map()})

  @doc """
  Executes a list of tool calls, returning results and updated state.

  `classifier` determines if each tool call is `:local` or `:subagent`.
  `local_handler` executes local tool calls.
  `spawner` handles subagent delegation (optional, defaults to raising).

  Local handler errors are caught and returned as error results.
  """
  @spec execute([Message.ToolCall.t()], map(), classifier(), local_handler(), spawner()) ::
          {[Message.ToolResult.t()], map()}
  def execute(tool_calls, state, classifier, local_handler, spawner \\ &default_spawner/2) do
    {results, state} =
      Enum.map_reduce(tool_calls, state, fn tool_call, acc ->
        case classifier.(tool_call) do
          :local ->
            result = safe_execute(tool_call, local_handler)
            {result, acc}

          :subagent ->
            spawner.(tool_call, acc)
        end
      end)

    {results, state}
  end

  defp safe_execute(tool_call, handler) do
    handler.(tool_call)
  rescue
    error ->
      %Message.ToolResult{
        tool_call_id: tool_call.id,
        content: "Error: #{Exception.message(error)}",
        is_error: true
      }
  end

  defp default_spawner(_tool_call, _state) do
    raise "No spawner provided for subagent tool call"
  end
end
