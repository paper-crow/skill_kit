# Public API & Streaming Design

## Problem

SkillKit has no public API for starting agents or receiving output. Callers must manually look up internal processes via Registry, wire telemetry handlers to observe responses, and use workarounds to detect turn completion. The Server buffers entire LLM responses before decoding, preventing real-time text streaming.

## Design

### Public API

Three functions on the `SkillKit` module:

```elixir
@spec start_agent(Definition.t(), keyword()) :: {:ok, agent()} | {:error, term()}
@spec send_message(agent(), String.t()) :: :ok
@spec stop_agent(agent()) :: :ok
```

#### The `agent()` type

An opaque struct holding everything needed to interact with a running agent:

```elixir
defmodule SkillKit.AgentRef do
  @enforce_keys [:name, :registry, :supervisor_pid]
  defstruct [:name, :registry, :supervisor_pid]
end
```

- `name` — the agent's string name (used in event tuples)
- `registry` — the Elixir Registry name (for mailbox/server lookups)
- `supervisor_pid` — the top-level agent supervisor (for `stop_agent`)

#### `start_agent/2`

Accepts a `%SkillKit.Agent.Definition{}` and options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:sources` | `[{module, keyword}]` | `[]` | Kit loaders (was `backends`) |
| `:provider` | `{module, keyword}` | from app config | LLM provider (was `backend`/`server_opts`) |
| `:caller` | `pid()` | `self()` | Process that receives events |

Internally creates an Elixir `Registry` with a unique name, starts the `SkillKit.Agent` supervisor, and returns an `%AgentRef{}`.

```elixir
{:ok, agent} = SkillKit.start_agent(definition,
  sources: [{SkillKit.Backend.Filesystem, dirs: ["priv/skills"]}],
  provider: {SkillKit.LLM.Anthropic, [api_key: "sk-..."]},
  caller: self()
)
```

The Registry is started under the agent's own supervisor tree so it shares the agent's lifecycle. When the agent stops, the Registry stops.

#### `send_message/2`

Wraps the string in `%Message.User{content: text}`, looks up the agent's mailbox via the Registry, and casts the message. Returns `:ok` immediately.

```elixir
:ok = SkillKit.send_message(agent, "What is 2 + 2?")
```

Messages sent while a turn is in progress are queued in the Mailbox and processed after the current turn completes. This is natural GenServer message ordering — no special handling needed.

#### `stop_agent/1`

Stops the agent's supervisor tree synchronously via `Supervisor.stop/1`. This also stops the internally-created Registry. Returns `:ok`.

### Events

The caller process receives three event types:

```elixir
{:skill_kit, agent_name, {:delta, text}}     # Real-time text fragment
{:skill_kit, agent_name, {:response, text}}   # Complete text when turn ends
{:skill_kit, agent_name, {:error, reason}}    # LLM or execution error
```

- **Deltas** arrive as individual text fragments from the SSE stream.
- **Response** is sent once at the end of the turn with the full assembled text from the final LLM call (the one that ended without tool calls). If the final LLM call produced no text (e.g., only tool calls that resolved with `end_turn`), the response text is `nil`.
- **Tool calls are internal.** The caller does not receive tool_call or tool_result events. Telemetry remains available for observability.

### Streaming Architecture

#### Current flow (buffered)

```
LLM.stream → Enum.to_list() → Decoder.decode_events() → %Assistant{}
```

#### New flow (incremental)

```
LLM.stream → Enum.reduce(acc, fn event ->
  decode_event(event, acc)     # Accumulate state
  if text_delta → send delta   # Emit immediately
end) → %Assistant{}
```

Changes required:

1. **`Decoder.decode_event/2`** — New function. Processes a single SSE event against an accumulator. Returns `{action, updated_acc}` where action is `{:delta, text}` or `:none`. Tool use state is accumulated internally — no action is emitted for it since tool calls are extracted from the final accumulator when the stream ends.

2. **`Server.run_agent_loop/2`** — Replace `Enum.to_list() |> decode_events()` with `Enum.reduce/3` over the stream. On each `{:delta, text}` action, send `{:skill_kit, name, {:delta, text}}` to the caller. After the stream completes, build the final `%Assistant{}` from the accumulator.

3. **`Server` state** — Add `caller` field (pid). Set once at init time, passed through from `SkillKit.start_agent/2` → `Agent.start_link/1` → `Core` → `Server.init/1`. Not per-message — all events for this agent go to the same caller.

4. **Turn completion** — When the agent loop finishes (no more tool calls), send `{:skill_kit, name, {:response, full_text}}` to the caller.

5. **Multi-loop turns** — When tool calls trigger another LLM round, deltas from that round stream to the same caller. Only the final text response gets a `:response` event.

### Naming Changes

| Old | New | Files affected |
|-----|-----|-------|
| `backends` | `sources` | `Agent`, `Agent.Infrastructure`, `Supervisor`, `SkillKit` (new) |
| `backend` (LLM option) | `provider` | `Server` state, `Agent` opts, `LLM.stream/2` opts key, `SkillKit` (new) |
| `server_opts` | flattened into top-level opts | `Agent` opts |

The `SkillKit.Backend` behaviour module name stays unchanged. The `SkillKit.LLM` behaviour module name stays unchanged. Only the option keys in function signatures and structs change.

### Caller Plumbing

The `caller` pid is set once at `start_agent` time and stored in Server state. It is **not** threaded per-message through the Mailbox. The Mailbox API stays as-is (`{:message, message}` cast, `{:mailbox_flush, messages}` info). This keeps things simple — one agent, one caller.

### Error Handling

- LLM errors: Server sends `{:skill_kit, name, {:error, {status, body}}}` to caller for HTTP errors, or `{:skill_kit, name, {:error, reason}}` for transport errors.
- Server crash: Standard OTP — caller's monitor (if any) fires. The `:response` event will never arrive.

### Demo Task Simplification

The `Mix.Tasks.SkillKit.Demo` task drops all telemetry wiring and becomes:

```elixir
{:ok, agent} = SkillKit.start_agent(definition,
  provider: {SkillKit.LLM.Anthropic, [api_key: api_key]},
  caller: self()
)

SkillKit.send_message(agent, prompt)

receive_loop(definition.name)
```

Where `receive_loop` pattern-matches on `{:skill_kit, name, event}` messages.

## Scope

### In scope
- `SkillKit.start_agent/2`, `send_message/2`, `stop_agent/1`
- `SkillKit.AgentRef` struct
- Incremental SSE decoding with delta emission (`Decoder.decode_event/2`)
- Rename `backends` → `sources`, `backend` → `provider`
- Caller pid in Server state (set once at init)
- Simplified demo task

### Out of scope
- Multi-turn conversation management (already works via repeated `send_message`)
- Phoenix-specific adapters or PubSub integration
- Token-level usage/metadata events
- Changing the `SkillKit.Backend` or `SkillKit.LLM` behaviour module names
- Backpressure / flow control on caller mailbox (unlikely to be a problem for single-agent use)

## Testing Strategy

- **Unit**: `Decoder.decode_event/2` returns correct actions for each SSE event type
- **Unit**: Server sends delta/response/error messages to caller pid (Mox the LLM)
- **Unit**: Multi-loop turn — tool call triggers second LLM call, deltas from both rounds arrive, only final text in `:response`
- **Unit**: LLM error sends `{:error, reason}` to caller, server stays alive
- **Integration**: `SkillKit.start_agent` + `send_message` + receive loop with mocked LLM
- **Integration**: `stop_agent` cleans up supervisor and registry
- **Existing tests**: Update to use new naming (`sources`, `provider`)
