defmodule SkillKit.LLM.Anthropic.Encoder do
  @moduledoc """
  Translates SkillKit.Types message structs to Anthropic Messages API format.
  """

  alias SkillKit.Types

  @doc """
  Encodes a list of native message structs into Anthropic API message format.

  Consecutive ToolResult messages are grouped into a single user message
  with tool_result content blocks, as required by the Anthropic API.
  """
  @spec encode_messages([Types.message()]) :: [map()]
  def encode_messages(messages) do
    messages
    |> chunk_tool_results()
    |> Enum.map(&encode_chunk/1)
  end

  # Groups consecutive ToolResult messages into lists. All other messages
  # stay as single-element lists.
  defp chunk_tool_results(messages) do
    messages
    |> Enum.reduce({[], []}, fn
      %Types.ToolResult{} = tr, {chunks, acc} ->
        {chunks, [tr | acc]}

      msg, {chunks, []} ->
        {chunks ++ [[msg]], []}

      msg, {chunks, acc} ->
        {chunks ++ [Enum.reverse(acc), [msg]], []}
    end)
    |> then(fn
      {chunks, []} -> chunks
      {chunks, acc} -> chunks ++ [Enum.reverse(acc)]
    end)
  end

  defp encode_chunk([%Types.ToolResult{} | _] = results) do
    blocks = Enum.map(results, &encode_tool_result/1)
    %{"role" => "user", "content" => blocks}
  end

  defp encode_chunk([message]) do
    encode_message(message)
  end

  defp encode_message(%Types.UserMessage{content: content}) do
    %{"role" => "user", "content" => content}
  end

  defp encode_message(%Types.AssistantMessage{content: content, tool_calls: []}) do
    %{"role" => "assistant", "content" => content}
  end

  defp encode_message(%Types.AssistantMessage{content: content, tool_calls: tool_calls}) do
    text_block = if content, do: [%{"type" => "text", "text" => content}], else: []

    tool_blocks =
      Enum.map(tool_calls, fn %Types.ToolCall{id: id, name: name, input: input} ->
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      end)

    %{"role" => "assistant", "content" => text_block ++ tool_blocks}
  end

  defp encode_message(%Types.SystemMessage{content: content}) do
    %{"role" => "user", "content" => content}
  end

  defp encode_tool_result(%Types.ToolResult{
         tool_call_id: id,
         content: content,
         is_error: is_error
       }) do
    result = %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
    if is_error, do: Map.put(result, "is_error", true), else: result
  end

  @doc "Encodes ToolDefinition structs into Anthropic tool format."
  def encode_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "input_schema" => tool.input_schema
      }
    end)
  end
end
