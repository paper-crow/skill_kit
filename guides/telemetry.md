# Telemetry

SkillKit instruments all meaningful runtime activity through the
[`:telemetry`](https://hexdocs.pm/telemetry) library. Every agent turn,
LLM call, tool execution, and rate-limit retry emits a structured event
that you can forward to any metrics or logging backend without modifying
SkillKit itself.

Two namespaces are used:

- `[:skill_kit, ...]` — high-level agent and LLM pipeline events
- `[:anthropic, ...]` — low-level HTTP client events for the Anthropic API

All durations are in `:native` time units (convert with
`System.convert_time_unit/3`).

---

## SkillKit events

### Agent events

| Event | Kind | Description |
|---|---|---|
| `[:skill_kit, :agent, :turn, :start]` | span start | A new batch of messages begins processing |
| `[:skill_kit, :agent, :turn, :stop]` | span stop | The agent turn completed successfully |
| `[:skill_kit, :agent, :usage]` | point | Token usage totals for one LLM call |
| `[:skill_kit, :agent, :response]` | point | The final assistant message for one loop iteration |
| `[:skill_kit, :agent, :error]` | point | The LLM call returned an error |
| `[:skill_kit, :agent, :tool_call]` | point | A tool call is about to be dispatched |
| `[:skill_kit, :agent, :tool_result]` | point | A tool call returned a result |
| `[:skill_kit, :agent, :subagent_result]` | point | A spawned subagent reported its result |
| `[:skill_kit, :agent, :orphaned_result]` | point | A subagent tried to report but its parent was not found |

#### Measurements and metadata

| Event | Measurements | Metadata keys |
|---|---|---|
| `:turn, :start` | `:system_time`, `:message_count` | `:agent_name` |
| `:turn, :stop` | `:duration` | `:agent_name` |
| `:usage` | `:input_tokens`, `:output_tokens` | `:agent_name` |
| `:response` | `%{}` | `:agent_name`, `:response` (`AssistantMessage.t()`) |
| `:error` | `%{}` | `:agent_name`, `:error` (term) |
| `:tool_call` | `%{}` | `:agent_name`, `:tool_call` (`ToolCall.t()`) |
| `:tool_result` | `%{}` | `:agent_name`, `:tool_call_id`, `:result` (`ToolResult.t()`) |
| `:subagent_result` | `%{}` | `:agent_name`, `:subagent_name`, `:task`, `:result` (string) |
| `:orphaned_result` | `%{}` | `:agent_name`, `:parent_name`, `:result` (string) |

### LLM events

| Event | Kind | Description |
|---|---|---|
| `[:skill_kit, :llm, :stream, :start]` | span start | An LLM stream is about to begin |
| `[:skill_kit, :llm, :stream, :stop]` | span stop | Stream completed (success or error) |
| `[:skill_kit, :llm, :stream, :error]` | point | Model URI could not be resolved before the stream |

#### Measurements and metadata

| Event | Measurements | Metadata keys |
|---|---|---|
| `:stream, :start` | `system_time` | `:provider` (module), `:model` (string) |
| `:stream, :stop` | `duration` | `:provider`, `:model`, `:error` (on failure) |
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

### Hook boundary spans

`Hooks.call/4` wraps each gated boundary crossing in a telemetry span. These
events let you measure the latency of individual boundary types and observe
which hooks allowed, denied, or suspended a crossing.

| Event | Kind | Description |
|---|---|---|
| `[:skill_kit, :hook, :boundary, :start]` | span start | A gated boundary crossing is about to begin |
| `[:skill_kit, :hook, :boundary, :stop]` | span stop | The boundary crossing completed (allowed or denied) |
| `[:skill_kit, :hook, :boundary, :exception]` | span exception | A hook handler raised an exception |

#### Measurements and metadata

| Event | Measurements | Metadata keys |
|---|---|---|
| `:boundary, :start` | `:system_time` | `:agent_name`, `:event` (boundary event atom) |
| `:boundary, :stop` | `:duration` | `:agent_name`, `:event`, `:outcome` (`:ok \| :deny \| :pending`) |
| `:boundary, :exception` | `:duration`, `kind`, `reason`, `stacktrace` | `:agent_name`, `:event` |

To observe every tool-use boundary crossing:

```elixir
SkillKit.Telemetry.attach_many(
  :hook_spans,
  [
    [:skill_kit, :hook, :boundary, :start],
    [:skill_kit, :hook, :boundary, :stop]
  ],
  fn event, measurements, %{event: boundary, outcome: outcome} = meta, _ ->
    Logger.debug("boundary #{boundary} #{List.last(event)}: #{outcome}")
  end,
  %{}
)
```

---

## Attaching handlers

`SkillKit.Telemetry.attach_many/4` delegates to `:telemetry.attach_many/4`.
Handler functions must match `(event, measurements, metadata, config)`.

```elixir
SkillKit.Telemetry.attach_many(
  :my_app_telemetry,
  [
    [:skill_kit, :agent, :turn, :stop],
    [:skill_kit, :agent, :usage],
    [:anthropic, :rate_limited]
  ],
  &MyApp.TelemetryHandler.handle_event/4,
  %{}
)

# Cleanup:
SkillKit.Telemetry.detach(:my_app_telemetry)
```

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
    [:skill_kit, :agent, :turn, :stop],
    [:skill_kit, :agent, :usage]
  ]
  test "agent emits turn and usage events" do
    # ... trigger agent activity ...

    assert_receive {__MODULE__, [:skill_kit, :agent, :turn, :stop], meta}
    assert meta.agent_name == :my_agent

    assert_receive {__MODULE__, [:skill_kit, :agent, :usage], measurements}
    assert measurements.input_tokens > 0
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
    [:skill_kit, :agent, :turn, :stop],
    [:skill_kit, :agent, :error],
    [:anthropic, :rate_limited]
  ]

  def attach, do: SkillKit.Telemetry.attach_many(__MODULE__, @events, &handle_event/4, %{})

  def handle_event([:skill_kit, :agent, :turn, :stop], %{duration: d}, %{agent_name: name}, _) do
    Logger.info("[#{name}] turn completed in #{System.convert_time_unit(d, :native, :millisecond)}ms")
  end

  def handle_event([:skill_kit, :agent, :error], _, %{agent_name: name, error: err}, _) do
    Logger.error("[#{name}] LLM error: #{inspect(err)}")
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
    Metrics.sum("skill_kit.agent.usage.input_tokens", tags: [:agent_name]),
    Metrics.sum("skill_kit.agent.usage.output_tokens", tags: [:agent_name]),
    Metrics.distribution("skill_kit.agent.turn.stop.duration",
      unit: {:native, :millisecond}, tags: [:agent_name]),
    Metrics.counter("anthropic.rate_limited", tags: [:endpoint])
  ]
end
```
