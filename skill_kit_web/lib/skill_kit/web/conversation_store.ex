defmodule SkillKit.Web.ConversationStore do
  @moduledoc """
  Filesystem-backed conversation store that persists messages as JSON files.

  Uses JSON serialization (via Jason) instead of Erlang binary format,
  making conversations human-readable and debuggable.

  ## Options

    * `:dir` - directory for storing conversation files.
      Defaults to `<project_root>/.skill_kit/conversations`.

  ## Usage

      {SkillKit.Web.ConversationStore, dir: "/path/to/conversations"}

  """

  @behaviour SkillKit.Conversation.Store

  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.SystemMessage
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.ToolResult
  alias SkillKit.Types.UserMessage

  @impl true
  def save(conversation_id, messages, opts) do
    path = conversation_path(conversation_id, opts)
    File.mkdir_p!(Path.dirname(path))
    json = Jason.encode!(Enum.map(messages, &serialize_message/1), pretty: true)
    File.write(path, json)
  end

  @impl true
  def load(conversation_id, opts) do
    path = conversation_path(conversation_id, opts)

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, decoded} ->
            {:ok, Enum.map(decoded, &deserialize_message/1)}

          {:error, _} ->
            {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(conversation_id, opts) do
    path = conversation_path(conversation_id, opts)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Serialization

  defp serialize_message(%UserMessage{} = msg) do
    %{role: "user", content: msg.content, agent: msg.agent}
  end

  defp serialize_message(%AssistantMessage{} = msg) do
    %{
      role: "assistant",
      content: msg.content,
      agent: msg.agent,
      tool_calls: Enum.map(msg.tool_calls, &serialize_tool_call/1)
    }
  end

  defp serialize_message(%SystemMessage{} = msg) do
    %{role: "system", content: msg.content, agent: msg.agent}
  end

  defp serialize_message(%ToolResult{} = msg) do
    %{
      role: "tool_result",
      tool_call_id: msg.tool_call_id,
      content: msg.content,
      name: msg.name,
      agent: msg.agent,
      is_error: msg.is_error
    }
  end

  defp serialize_tool_call(%ToolCall{} = tc) do
    %{id: tc.id, name: tc.name, input: tc.input}
  end

  # Deserialization

  defp deserialize_message(%{"role" => "user"} = data) do
    %UserMessage{content: data["content"], agent: data["agent"]}
  end

  defp deserialize_message(%{"role" => "assistant"} = data) do
    tool_calls = Enum.map(data["tool_calls"] || [], &deserialize_tool_call/1)

    %AssistantMessage{
      content: data["content"],
      agent: data["agent"],
      tool_calls: tool_calls
    }
  end

  defp deserialize_message(%{"role" => "system"} = data) do
    %SystemMessage{content: data["content"], agent: data["agent"]}
  end

  defp deserialize_message(%{"role" => "tool_result"} = data) do
    %ToolResult{
      tool_call_id: data["tool_call_id"],
      content: data["content"],
      name: data["name"],
      agent: data["agent"],
      is_error: data["is_error"] || false
    }
  end

  defp deserialize_tool_call(data) do
    %ToolCall{id: data["id"], name: data["name"], input: data["input"]}
  end

  defp conversation_path(conversation_id, opts) do
    dir = Keyword.get(opts, :dir, default_dir())
    safe_id = String.replace(conversation_id, ~r/[^\w-]/, "_")
    Path.join(dir, "#{safe_id}.json")
  end

  defp default_dir do
    Path.join(SkillKitWeb.project_root(), ".skill_kit/conversations")
  end
end
