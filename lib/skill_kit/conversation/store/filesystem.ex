defmodule SkillKit.Conversation.Store.Filesystem do
  @moduledoc """
  Stores conversations as serialized Erlang terms on disk.

  Uses `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1` for
  safe serialization of message structs.

  ## Config

      {SkillKit.Conversation.Store.Filesystem, path: ".conversations"}
  """

  @behaviour SkillKit.Conversation.Store

  @impl true
  def save(conversation_id, messages, config) do
    path = conversation_path(conversation_id, config)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, :erlang.term_to_binary(messages))
  end

  @impl true
  def load(conversation_id, config) do
    path = conversation_path(conversation_id, config)

    case File.read(path) do
      {:ok, binary} ->
        messages = :erlang.binary_to_term(binary)
        {:ok, messages}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(conversation_id, config) do
    path = conversation_path(conversation_id, config)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp conversation_path(conversation_id, config) do
    base = Keyword.fetch!(config, :path)
    safe_id = String.replace(conversation_id, ~r/[^\w-]/, "_")
    Path.join(base, "#{safe_id}.bin")
  end
end
