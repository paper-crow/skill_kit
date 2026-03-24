# Conversations

Agents are stateless between restarts by default. Each `SkillKit.start_agent/2`
call starts with an empty message history. If the agent is stopped and
restarted, previous messages are lost.

A **conversation store** solves this by persisting messages to durable storage.
When the agent starts, it loads prior messages. After each turn completes, it
saves the updated history. This enables multi-session conversations, crash
recovery, and conversation audit trails.

## When to use a store

- **Multi-session agents** — a user returns hours later and the agent
  remembers the conversation
- **Crash recovery** — if the agent process crashes, the supervisor restarts
  it and the store restores state
- **Audit and debugging** — inspect what the agent said and which tools it
  called

If your agent is ephemeral (single request, no persistence needed), skip the
store entirely. The default is `nil` — no persistence.

## Configuring a store

Pass `conversation_store: {module, config}` to `SkillKit.start_agent/2`:

```elixir
{:ok, agent} = SkillKit.start_agent(definition,
  caller: self(),
  conversation_store: {SkillKit.Conversation.Store.Filesystem, path: "priv/conversations"}
)
```

The store is a `{module, config}` tuple. The module implements
`SkillKit.Conversation.Store`. The config is a keyword list passed to every
callback.

## How it works

1. **On init** — the Server calls `store.load(agent_name, config)`. If
   messages exist, they become the starting conversation history. If the
   store returns `{:error, _}` or the file doesn't exist, the agent starts
   with an empty history.

2. **After each turn** — the Server calls `store.save(agent_name, messages, config)`
   with the full message list. This happens after the agent loop completes,
   including any tool call rounds.

3. **On delete** — `store.delete(agent_name, config)` removes the stored
   conversation. This is not called automatically — use it when you want to
   clear history explicitly.

The conversation ID is the agent's name (a string).

## The Store behaviour

`SkillKit.Conversation.Store` defines three callbacks:

```elixir
@callback save(conversation_id, [message], keyword()) :: :ok | {:error, term()}
@callback load(conversation_id, keyword()) :: {:ok, [message]} | {:error, term()}
@callback delete(conversation_id, keyword()) :: :ok | {:error, term()}
```

Messages are `SkillKit.Types` structs: `%UserMessage{}`, `%AssistantMessage{}`,
`%SystemMessage{}`, `%ToolResult{}`.

## Built-in: Filesystem store

`SkillKit.Conversation.Store.Filesystem` serializes messages as Erlang binary
terms on disk.

```elixir
{SkillKit.Conversation.Store.Filesystem, path: "priv/conversations"}
```

Files are stored at `{path}/{agent_name}.bin`. The agent name is sanitized
(non-word characters replaced with `_`). Uses `:erlang.term_to_binary/1` for
serialization — fast and lossless for Elixir structs.

This store is suitable for development and single-node deployments. For
distributed systems, implement a database-backed store.

## Writing a custom store

Implement `SkillKit.Conversation.Store` for your storage backend:

```elixir
defmodule MyApp.ConversationStore.Postgres do
  @behaviour SkillKit.Conversation.Store

  @impl true
  def save(conversation_id, messages, _config) do
    encoded = :erlang.term_to_binary(messages)

    MyApp.Repo.insert_or_update!(
      %MyApp.Conversation{id: conversation_id, messages: encoded}
    )

    :ok
  end

  @impl true
  def load(conversation_id, _config) do
    case MyApp.Repo.get(MyApp.Conversation, conversation_id) do
      nil -> {:ok, []}
      record -> {:ok, :erlang.binary_to_term(record.messages)}
    end
  end

  @impl true
  def delete(conversation_id, _config) do
    MyApp.Repo.delete_all(
      from(c in MyApp.Conversation, where: c.id == ^conversation_id)
    )

    :ok
  end
end
```

Then use it:

```elixir
{:ok, agent} = SkillKit.start_agent(definition,
  conversation_store: {MyApp.ConversationStore.Postgres, []}
)
```

## Testing with stores

Use a temporary directory with `SkillKit.Conversation.Store.Filesystem`:

```elixir
setup do
  path = Path.join(System.tmp_dir!(), "test_store_#{:erlang.unique_integer([:positive])}")
  File.mkdir_p!(path)
  on_exit(fn -> File.rm_rf!(path) end)

  %{store: {SkillKit.Conversation.Store.Filesystem, path: path}}
end

test "persists messages across agent restarts", %{store: store} do
  definition = %SkillKit.Agent.Definition{...}

  # First session
  SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "Hi!"})
  {:ok, agent} = SkillKit.start_agent(definition, conversation_store: store, caller: self())
  {:ok, _msg} = SkillKit.send_message_sync(agent, "Hello")
  Process.sleep(100)  # wait for async save
  SkillKit.stop_agent(agent)

  # Second session — agent should remember
  SkillKit.Test.assert_response(%SkillKit.Response.Text{content: "I remember!"}, fn messages, _opts ->
    assert length(messages) > 1  # prior messages loaded
  end)
  {:ok, agent2} = SkillKit.start_agent(definition, conversation_store: store, caller: self())
  {:ok, _msg} = SkillKit.send_message_sync(agent2, "Do you remember?")
end
```
