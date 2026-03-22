defmodule SkillKit.LLM.Anthropic.Decoder do
  @moduledoc """
  Parses Anthropic SSE stream events into SkillKit.LLM.Message structs.

  Collects streaming events (content_block_start, content_block_delta,
  content_block_stop, etc.) into a single `%Assistant{}` response with
  accumulated text and parsed tool calls.
  """

  alias SkillKit.LLM.Message

  @doc """
  Decodes a list of Anthropic SSE events into a single `%Message.Assistant{}`.

  Accumulates text deltas and tool use input JSON deltas across events.
  """
  @spec decode_events([map()]) :: Message.Assistant.t()
  def decode_events(events) do
    state = %{blocks: %{}, text: "", tool_calls: []}

    result =
      Enum.reduce(events, state, fn event, acc ->
        process_event(event, acc)
      end)

    content = if result.text == "", do: nil, else: result.text

    %Message.Assistant{
      content: content,
      tool_calls: Enum.reverse(result.tool_calls)
    }
  end

  defp process_event(%{"type" => "content_block_start", "index" => index, "content_block" => block}, state) do
    put_in(state, [:blocks, index], block)
  end

  defp process_event(%{"type" => "content_block_delta", "index" => index, "delta" => delta}, state) do
    case delta do
      %{"type" => "text_delta", "text" => text} ->
        %{state | text: state.text <> text}

      %{"type" => "input_json_delta", "partial_json" => json} ->
        update_in(state, [:blocks, index], fn block ->
          Map.update(block, "partial_input", json, &(&1 <> json))
        end)

      _ ->
        state
    end
  end

  defp process_event(%{"type" => "content_block_stop", "index" => index}, state) do
    case get_in(state, [:blocks, index]) do
      %{"type" => "tool_use", "id" => id, "name" => name} = block ->
        input_json = Map.get(block, "partial_input", "{}")
        input = Jason.decode!(input_json)

        tool_call = %Message.ToolCall{id: id, name: name, input: input}
        %{state | tool_calls: [tool_call | state.tool_calls]}

      _ ->
        state
    end
  end

  defp process_event(_event, state), do: state
end
