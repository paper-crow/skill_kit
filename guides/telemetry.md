# Telemetry

SkillKit instruments all meaningful runtime activity through the
[`:telemetry`](https://hexdocs.pm/telemetry) library. Every agent turn,
LLM call, tool execution, and rate-limit retry emits a structured event
that you can forward to any metrics or logging backend without modifying
SkillKit itself.

Two namespaces are used:

- `[:skill_kit, ...]` — agent boundary spans and LLM pipeline events
- `[:anthropic, ...]` — low-level HTTP client events for the Anthropic API

All durations are in `:native` time units (convert with
`System.convert_time_unit/3`).

---

## SkillKit events

### Boundary spans

Each agent boundary emits a telemetry span, letting you measure latency
per boundary type and observe which crossings were allowed, denied, or
suspended.

| Event | Kind | Description |
|---|---|---|
| `[:skill_kit, :tool_use, :start/:stop]` | span | Individual tool execution |
| `[:skill_kit, :tool_batch, :start/:stop]` | span | Batch of parallel tool calls (wraps all `:tool_use` spans in one LLM turn) |
| `[:skill_kit, :subagent, :start/:stop]` | span | Spawning a subagent |
| `[:skill_kit, :conversation_save, :start/:stop]` | span | Persisting conversation history |
| `[:skill_kit, :conversation_load, :start/:stop]` | span | Loading conversation history |
| `[:skill_kit, :llm_request, :start/:stop]` | span | Sending a request to the LLM |
| `[:skill_kit, :turn, :start/:stop]` | span | Processing a batch of messages |

Each span emits a `:start` event (with `:system_time`) and a `:stop` event
(with `:duration`). The metadata map contains the boundary context keys
described in the [Hooks guide](hooks-and-execution.md#hook-context).

The `:tool_batch` span wraps the entire parallel execution of tool calls
returned by a single LLM response. Its metadata includes:

- `:agent_name` — the agent executing the batch
- `:tool_count` — number of tool calls in the batch
- `:tool_names` — list of tool names being executed

If any tool in the batch suspends (via `{:pending, state}`), the
`:tool_batch` span includes the time waiting for `SkillKit.respond/3`.

To observe every tool-use boundary crossing:

```elixir
SkillKit.Telemetry.attach_many(
  :tool_use_spans,
  [
    [:skill_kit, :tool_use, :start],
    [:skill_kit, :tool_use, :stop]
  ],
  fn event, measurements, meta, _ ->
    IO.inspect({List.last(event), meta.agent_name, meta.tool})
  end,
  %{}
)
```

To measure total batch execution time (including suspension waits):

```elixir
SkillKit.Telemetry.attach_many(
  :tool_batch_spans,
  [[:skill_kit, :tool_batch, :stop]],
  fn _event, %{duration: d}, meta, _ ->
    ms = System.convert_time_unit(d, :native, :millisecond)
    IO.puts("[#{meta.agent_name}] #{meta.tool_count} tools completed in #{ms}ms")
  end,
  %{}
)
```

### LLM events

| Event | Kind | Description |
|---|---|---|
| `[:skill_kit, :llm, :stream, :start]` | span start | An LLM stream is about to begin |
| `[:skill_kit, :llm, :stream, :stop]` | span stop | Stream completed (success or error) |
| `[:skill_kit, :llm, :stream, :error]` | point | Model URI could not be resolved before the stream |

#### Measurements and metadata

| Event | Measurements | Metadata keys |
|---|---|---|
| `:stream, :start` | `:system_time` | `:provider` (module), `:model` (string) |
| `:stream, :stop` | `:duration` | `:provider`, `:model`, `:error` (on failure) |
| `:stream, :error` | `%{}` | `:error` (the `{:error, _}` tuple), `:model` (string) |

---

## Anthropic events

These events are emitted by the HTTP client layer regardless of which
SkillKit agent triggered the request.

| Event | Kind | Description |
|---|---|---|
| `[:anthropic, :request, :start]` | span start | Before an API request is sent |
| `[:anthropic, :request, :stop]` | span stop | After a successful response |
| `[:anthropic, :request, :exception]` | span exception | On request failure or exception |
| `[:anthropic, :rate_limited]` | point | A 429 response triggered an automatic retry |

#### Measurements and metadata

| Event | Measurements | Metadata keys |
|---|---|---|
| `:request, :start` | `system_time` | *(provider-defined)* |
| `:request, :stop` | `duration` | *(provider-defined)* |
| `:request, :exception` | `duration`, `kind`, `reason`, `stacktrace` | *(provider-defined)* |
| `:rate_limited` | `:retry_after` (ms), `:attempt` (integer) | `:endpoint` (string) |

---

## Attaching handlers

`SkillKit.Telemetry.attach_many/4` delegates to `:telemetry.attach_many/4`.
Handler functions must match `(event, measurements, metadata, config)`.

```elixir
SkillKit.Telemetry.attach_many(
  :my_app_telemetry,
  [
    [:skill_kit, :turn, :stop],
    [:skill_kit, :llm_request, :stop],
    [:anthropic, :rate_limited]
  ],
  &MyApp.TelemetryHandler.handle_event/4,
  %{}
)

# Cleanup:
SkillKit.Telemetry.detach(:my_app_telemetry)
```

Alternatively, implement `SkillKit.Telemetry.Handler` to create a
supervised GenServer handler:

```elixir
defmodule MyApp.Handlers.TurnLogger do
  use SkillKit.Telemetry.Handler, events: [
    [:skill_kit, :turn, :stop]
  ]

  @impl true
  def handle_event([:skill_kit, :turn, :stop], measurements, metadata) do
    Logger.info("[#{metadata.agent_name}] turn completed in #{measurements.duration}ns")
    :ok
  end
end
```

Add it to your supervision tree and it will subscribe automatically on startup.

---

## Testing telemetry

`SkillKit.TelemetryHelper` wires up a per-test telemetry handler that
forwards events to the test process as messages.

```elixir
defmodule MyApp.AgentTest do
  use ExUnit.Case, async: true

  import SkillKit.TelemetryHelper

  setup :telemetry

  @tag telemetry: [
    [:skill_kit, :turn, :stop],
    [:skill_kit, :tool_use, :stop]
  ]
  test "agent emits turn and tool_use spans" do
    # ... trigger agent activity ...

    assert_receive {__MODULE__, [:skill_kit, :turn, :stop], meta}
    assert meta.agent_name == "my_agent"

    assert_receive {__MODULE__, [:skill_kit, :tool_use, :stop], _meta}
  end
end
```

`setup :telemetry` is a no-op when no `@tag telemetry:` is present, so it
is safe in a shared `setup` block. Handlers are detached after each test.

---

## Example: logger and metrics

A handler module that logs key events:

```elixir
defmodule MyApp.TelemetryLogger do
  require Logger

  @events [
    [:skill_kit, :turn, :stop],
    [:skill_kit, :llm_request, :stop],
    [:anthropic, :rate_limited]
  ]

  def attach, do: SkillKit.Telemetry.attach_many(__MODULE__, @events, &handle_event/4, %{})

  def handle_event([:skill_kit, :turn, :stop], %{duration: d}, %{agent_name: name}, _) do
    Logger.info("[#{name}] turn completed in #{System.convert_time_unit(d, :native, :millisecond)}ms")
  end

  def handle_event([:skill_kit, :llm_request, :stop], %{duration: d}, meta, _) do
    Logger.debug("[#{meta.agent_name}] LLM request in #{System.convert_time_unit(d, :native, :millisecond)}ms")
  end

  def handle_event([:anthropic, :rate_limited], %{retry_after: ms, attempt: n}, _, _) do
    Logger.warning("Rate limited — retrying in #{ms}ms (attempt #{n})")
  end
end
```

For structured metrics with `:telemetry_metrics` (Prometheus, StatsD, etc.):

```elixir
def metrics do
  [
    Metrics.distribution("skill_kit.turn.stop.duration",
      unit: {:native, :millisecond}, tags: [:agent_name]),
    Metrics.distribution("skill_kit.tool_use.stop.duration",
      unit: {:native, :millisecond}, tags: [:agent_name]),
    Metrics.counter("anthropic.rate_limited", tags: [:endpoint])
  ]
end
```
