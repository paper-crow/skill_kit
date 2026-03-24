defmodule SkillKit.Conversation.Store do
  @moduledoc """
  Behaviour for conversation persistence backends.

  Implementations store and retrieve conversation message history,
  enabling agents to resume conversations after restarts.
  """

  @type conversation_id :: String.t()
  @type message ::
          SkillKit.Types.UserMessage.t()
          | SkillKit.Types.AssistantMessage.t()
          | SkillKit.Types.SystemMessage.t()
          | SkillKit.Types.ToolResult.t()

  @callback save(conversation_id(), [message()], keyword()) :: :ok | {:error, term()}
  @callback load(conversation_id(), keyword()) :: {:ok, [message()]} | {:error, term()}
  @callback delete(conversation_id(), keyword()) :: :ok | {:error, term()}
end
