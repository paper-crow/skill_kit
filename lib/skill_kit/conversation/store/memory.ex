defmodule SkillKit.Conversation.Store.Memory do
  @moduledoc """
  In-memory conversation store backed by an `Agent` process.

  Designed for testing. Stores messages in a map keyed by conversation ID.
  Optionally notifies a process on each save, which is useful for asserting
  that persistence happened without polling.

  ## Config

      {:ok, pid} = SkillKit.Conversation.Store.Memory.start_link()
      {SkillKit.Conversation.Store.Memory, pid: pid}

  ## Notifications

  Pass `notify: pid` in the config to receive messages on save:

      {SkillKit.Conversation.Store.Memory, pid: pid, notify: self()}

  Each save sends `{:memory_store, :save, conversation_id, messages}` to
  the notify process.
  """

  @behaviour SkillKit.Conversation.Store

  @doc "Starts a new in-memory store process."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts)
  end

  @impl true
  def save(conversation_id, messages, config) do
    pid = Keyword.fetch!(config, :pid)
    Agent.update(pid, &Map.put(&1, conversation_id, messages))
    maybe_notify(config, conversation_id, messages)
    :ok
  end

  @impl true
  def load(conversation_id, config) do
    pid = Keyword.fetch!(config, :pid)
    messages = Agent.get(pid, &Map.get(&1, conversation_id, []))
    {:ok, messages}
  end

  @impl true
  def delete(conversation_id, config) do
    pid = Keyword.fetch!(config, :pid)
    Agent.update(pid, &Map.delete(&1, conversation_id))
    :ok
  end

  defp maybe_notify(config, conversation_id, messages) do
    case Keyword.fetch(config, :notify) do
      {:ok, pid} -> send(pid, {:memory_store, :save, conversation_id, messages})
      :error -> :ok
    end
  end
end
