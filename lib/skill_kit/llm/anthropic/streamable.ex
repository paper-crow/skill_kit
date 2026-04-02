defimpl SkillKit.Event.Streamable, for: Anthropic.Event.MessageStart do
  alias SkillKit.Event.Usage

  def stream(%{usage: usage}, acc) when is_map(usage) do
    {[%Usage{input_tokens: usage["input_tokens"] || 0, output_tokens: 0}], acc}
  end

  def stream(_, acc), do: {[], acc}
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.ContentBlockStart do
  alias SkillKit.Event.ToolCallStart

  def stream(%{index: idx, content_block: %{type: :tool_use, id: id, name: name}}, acc) do
    acc = put_in(acc, [:blocks, idx], %{type: :tool_use, id: id, name: name})
    {[%ToolCallStart{id: id, name: name}], acc}
  end

  def stream(%{index: idx, content_block: %{type: :text}}, acc) do
    acc = put_in(acc, [:blocks, idx], %{type: :text})
    {[], acc}
  end
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.ContentBlockDelta do
  alias SkillKit.Event.Delta

  def stream(%{delta: %{type: :text_delta, text: text}}, acc) do
    {[%Delta{text: text}], acc}
  end

  def stream(%{index: idx, delta: %{type: :input_json_delta, partial_json: json}}, acc) do
    acc = accumulate_json(acc, idx, json)
    {[], acc}
  end

  def stream(_event, acc), do: {[], acc}

  defp accumulate_json(acc, idx, json) do
    Map.update(acc, :partial_json, %{idx => json}, fn pj ->
      Map.update(pj, idx, json, &(&1 <> json))
    end)
  end
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.ContentBlockStop do
  alias SkillKit.Event.ToolCallComplete

  def stream(%{index: idx}, acc) do
    case get_in(acc, [:blocks, idx]) do
      %{type: :tool_use, id: id, name: name} -> build_tool_call_complete(id, name, idx, acc)
      _ -> {[], acc}
    end
  end

  defp build_tool_call_complete(id, name, idx, acc) do
    json = get_in(acc, [:partial_json, idx])
    input = decode_tool_input(json)
    {[%ToolCallComplete{id: id, name: name, input: input}], acc}
  end

  defp decode_tool_input(nil), do: %{}
  defp decode_tool_input(""), do: %{}
  defp decode_tool_input(json), do: Jason.decode!(json)
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.MessageDelta do
  alias SkillKit.Event.Done
  alias SkillKit.Event.Usage

  def stream(%{stop_reason: reason, usage: usage}, acc) when is_map(usage) do
    events = [
      %Usage{input_tokens: 0, output_tokens: usage["output_tokens"] || 0},
      %Done{stop_reason: reason}
    ]

    {events, acc}
  end

  def stream(%{stop_reason: reason}, acc) do
    {[%Done{stop_reason: reason}], acc}
  end
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.MessageStop do
  def stream(_, acc), do: {[], acc}
end
