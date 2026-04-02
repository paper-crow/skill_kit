defmodule SkillKit.Web.LiveConversationStore do
  @moduledoc """
  Conversation store that notifies a caller process on load, save, and delete.

  Wraps `SkillKit.Web.ConversationStore` (filesystem JSON) and sends
  messages to the `:caller` pid in opts so LiveViews can stay in sync
  with the agent's conversation state.

  ## Events sent to caller

    * `{:conversation_loaded, messages}` — after loading history
    * `{:conversation_saved, messages}` — after persisting messages
    * `{:conversation_deleted, conversation_id}` — after deletion

  ## Usage

      {LiveConversationStore, dir: conversations_dir, caller: self()}
  """

  @behaviour SkillKit.Conversation.Store

  alias SkillKit.Web.ConversationStore

  @impl true
  def load(conversation_id, opts) do
    result = ConversationStore.load(conversation_id, opts)

    case result do
      {:ok, messages} -> notify(opts, {:conversation_loaded, messages})
      _ -> :ok
    end

    result
  end

  @impl true
  def save(conversation_id, messages, opts) do
    result = ConversationStore.save(conversation_id, messages, opts)

    case result do
      :ok -> notify(opts, {:conversation_saved, messages})
      _ -> :ok
    end

    result
  end

  @impl true
  def delete(conversation_id, opts) do
    result = ConversationStore.delete(conversation_id, opts)

    case result do
      :ok -> notify(opts, {:conversation_deleted, conversation_id})
      _ -> :ok
    end

    result
  end

  defp notify(opts, message) do
    case Keyword.get(opts, :caller) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
