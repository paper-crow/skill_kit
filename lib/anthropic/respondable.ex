defimpl SkillKit.Response.Respondable, for: SkillKit.Response.Text do
  def to_stream(%{content: content}) do
    events = Anthropic.Test.text_events(content)
    {:ok, Stream.map(events, & &1)}
  end
end

defimpl SkillKit.Response.Respondable, for: SkillKit.Response.ToolCall do
  def to_stream(%{name: name, input: input}) do
    events = Anthropic.Test.tool_call_events(name, input)
    {:ok, Stream.map(events, & &1)}
  end
end

defimpl SkillKit.Response.Respondable, for: SkillKit.Response.Error do
  def to_stream(%{status: status, message: message}) do
    {:error, {status, message}}
  end
end
