defmodule SkillKit.LLM.Anthropic.Decoder do
  @moduledoc """
  Parses Anthropic SSE stream events into SkillKit.LLM.Message structs.

  Collects streaming events (content_block_start, content_block_delta,
  content_block_stop, etc.) into a single `%Assistant{}` response with
  accumulated text and parsed tool calls.
  """

  alias SkillKit.LLM.Message

  @doc """
  Returns a fresh accumulator for incremental event decoding.
  """
  @spec new_accumulator() :: map()
  def new_accumulator, do: %{blocks: %{}, text: "", tool_calls: [], usage: %{}}

  @doc """
  Decodes a single SSE event, returning an action and updated accumulator.

  Returns `{{:delta, text}, acc}` when new text is available, or `{:none, acc}` otherwise.
  """
  @spec decode_event(map(), map()) :: {{:delta, String.t()}, map()} | {:none, map()}
  def decode_event(event, acc) do
    new_acc = process_event(event, acc)
    delta = String.slice(new_acc.text, String.length(acc.text)..-1//1)

    if delta != "" do
      {{:delta, delta}, new_acc}
    else
      {:none, new_acc}
    end
  end

  @doc """
  Finalizes an accumulator into a `%Message.Assistant{}`.
  """
  @spec finalize(map()) :: Message.Assistant.t()
  def finalize(acc) do
    content = if acc.text == "", do: nil, else: acc.text

    %Message.Assistant{
      content: content,
      tool_calls: Enum.reverse(acc.tool_calls)
    }
  end

  @doc """
  Decodes a list of Anthropic SSE events into a single `%Message.Assistant{}`.

  Accumulates text deltas and tool use input JSON deltas across events.
  """
  @spec decode_events([map()]) :: Message.Assistant.t()
  def decode_events(events) do
    events
    |> Enum.reduce(new_accumulator(), fn event, acc ->
      {_action, acc} = decode_event(event, acc)
      acc
    end)
    |> finalize()
  end

  defp process_event(%{"type" => "message_start", "message" => %{"usage" => usage}}, state)
       when is_map(usage) do
    %{state | usage: Map.merge(state.usage, usage)}
  end

  defp process_event(%{"type" => "message_delta", "usage" => usage}, state)
       when is_map(usage) do
    %{state | usage: Map.merge(state.usage, usage)}
  end

  defp process_event(
         %{"type" => "content_block_start", "index" => index, "content_block" => block},
         state
       ) do
    put_in(state, [:blocks, index], block)
  end

  defp process_event(
         %{"type" => "content_block_delta", "index" => index, "delta" => delta},
         state
       ) do
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
