defmodule SkillKit.LLM.Anthropic.Encoder do
  @moduledoc """
  Translates SkillKit.Types message structs to Anthropic Messages API format.
  """

  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.SystemMessage
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.ToolResult
  alias SkillKit.Types.UserMessage

  @doc """
  Encodes a list of native message structs into Anthropic API message format.

  Consecutive ToolResult messages are grouped into a single user message
  with tool_result content blocks, as required by the Anthropic API.
  """
  @spec encode_messages([SkillKit.LLM.message()]) :: [map()]
  def encode_messages(messages) do
    messages
    |> chunk_tool_results()
    |> Enum.map(&encode_chunk/1)
  end

  @doc "Encodes Tool structs into Anthropic tool format."
  def encode_tools(tools) do
    Enum.map(tools, &encode_tool_definition/1)
  end

  # Groups consecutive ToolResult messages into lists. All other messages
  # stay as single-element lists.
  defp chunk_tool_results(messages) do
    {chunks, acc} =
      Enum.reduce(messages, {[], []}, fn
        %ToolResult{} = tr, {chunks, acc} ->
          {chunks, [tr | acc]}

        msg, {chunks, []} ->
          {chunks ++ [[msg]], []}

        msg, {chunks, acc} ->
          {chunks ++ [Enum.reverse(acc), [msg]], []}
      end)

    finalize_chunks(chunks, acc)
  end

  defp finalize_chunks(chunks, []), do: chunks
  defp finalize_chunks(chunks, acc), do: chunks ++ [Enum.reverse(acc)]

  defp encode_chunk([%ToolResult{} | _] = results) do
    %{"role" => "user", "content" => Enum.map(results, &encode_tool_result/1)}
  end

  defp encode_chunk([message]), do: encode_message(message)

  defp encode_message(%UserMessage{content: content}) do
    %{"role" => "user", "content" => content}
  end

  defp encode_message(%AssistantMessage{content: content, tool_calls: []}) do
    %{"role" => "assistant", "content" => content}
  end

  defp encode_message(%AssistantMessage{content: nil, tool_calls: tool_calls}) do
    %{"role" => "assistant", "content" => Enum.map(tool_calls, &encode_tool_call/1)}
  end

  defp encode_message(%AssistantMessage{content: content, tool_calls: tool_calls}) do
    text_block = [%{"type" => "text", "text" => content}]
    %{"role" => "assistant", "content" => text_block ++ Enum.map(tool_calls, &encode_tool_call/1)}
  end

  defp encode_message(%SystemMessage{content: content}) do
    %{"role" => "user", "content" => content}
  end

  defp encode_tool_call(%ToolCall{id: id, name: name, input: input}) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp encode_tool_result(%ToolResult{tool_call_id: id, content: content, is_error: true}) do
    %{"type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => true}
  end

  defp encode_tool_result(%ToolResult{tool_call_id: id, content: content}) do
    %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
  end

  defp encode_tool_definition(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "input_schema" => tool.input_schema
    }
  end

  @doc "Builds an ephemeral cache_control map for the given TTL."
  def cache_control("1h"), do: %{"type" => "ephemeral", "ttl" => "1h"}
  def cache_control(_ttl), do: %{"type" => "ephemeral"}

  @doc "Wraps a system prompt string in a cached text-block list."
  def cache_system(nil, _ttl), do: nil
  def cache_system("", _ttl), do: ""

  def cache_system(system, ttl) when is_binary(system) do
    [%{"type" => "text", "text" => system, "cache_control" => cache_control(ttl)}]
  end

  @doc "Tags the last content block of the last encoded message with cache_control."
  def cache_last_message([], _ttl), do: []

  def cache_last_message(messages, ttl) do
    {init, [last]} = Enum.split(messages, -1)
    init ++ [put_block_cache(last, ttl)]
  end

  defp put_block_cache(%{"content" => content} = message, ttl) when is_binary(content) do
    block = %{"type" => "text", "text" => content, "cache_control" => cache_control(ttl)}
    Map.put(message, "content", [block])
  end

  defp put_block_cache(%{"content" => blocks} = message, ttl)
       when is_list(blocks) and blocks != [] do
    {init, [last]} = Enum.split(blocks, -1)
    tagged = Map.put(last, "cache_control", cache_control(ttl))
    Map.put(message, "content", init ++ [tagged])
  end

  defp put_block_cache(message, _ttl), do: message
end
