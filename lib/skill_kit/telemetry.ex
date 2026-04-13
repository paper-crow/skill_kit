defmodule SkillKit.Telemetry do
  @moduledoc """
  Telemetry integration for SkillKit.

  All events are prefixed with `[:skill_kit]`. Unless specified,
  all times are in `:native` units.

  ## Boundary spans

  Each agent boundary emits a span with `:start` and `:stop` events:

  - `[:skill_kit, :tool_use, :start/:stop]` — individual tool execution
  - `[:skill_kit, :tool_batch, :start/:stop]` — batch of parallel tool calls
  - `[:skill_kit, :subagent, :start/:stop]` — spawning a subagent
  - `[:skill_kit, :conversation_save, :start/:stop]` — persisting history
  - `[:skill_kit, :conversation_load, :start/:stop]` — loading history
  - `[:skill_kit, :llm_request, :start/:stop]` — LLM API request
  - `[:skill_kit, :turn, :start/:stop]` — processing a message batch

  ## LLM events

  - `[:skill_kit, :llm, :stream, :start/:stop]` — LLM stream lifecycle
  - `[:skill_kit, :llm, :stream, :error]` — model URI resolution failure
  """

  def attach_many(name, events, handler, opts) do
    :telemetry.attach_many(name, events, handler, opts)
  end

  def detach(name) do
    :telemetry.detach(name)
  end

  @doc false
  def start(event, meta \\ %{}, extra_measurements \\ %{}) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      build_event_prefix(event, :start),
      Map.put(extra_measurements, :system_time, System.system_time()),
      meta
    )

    start_time
  end

  @doc false
  def stop(event, start_time, meta \\ %{}, extra_measurements \\ %{}) do
    end_time = System.monotonic_time()
    measurements = Map.put(extra_measurements, :duration, end_time - start_time)

    :telemetry.execute(
      build_event_prefix(event, :stop),
      measurements,
      meta
    )
  end

  @doc false
  def exception(event, start_time, kind, reason, stack, meta \\ %{}, extra_measurements \\ %{}) do
    end_time = System.monotonic_time()
    measurements = Map.put(extra_measurements, :duration, end_time - start_time)

    meta =
      meta
      |> Map.put(:kind, kind)
      |> Map.put(:reason, reason)
      |> Map.put(:stacktrace, stack)

    :telemetry.execute(build_event_prefix(event, :exception), measurements, meta)
  end

  @doc false
  def event(event, measurements, meta) do
    :telemetry.execute(build_event_prefix(event), measurements, meta)
  end

  @doc false
  def span(event, start_metadata, fun) do
    :telemetry.span(
      build_event_prefix(event),
      start_metadata,
      fun
    )
  end

  defp build_event_prefix(event, type \\ nil)

  defp build_event_prefix(event, nil) when is_list(event) do
    [:skill_kit | event]
  end

  defp build_event_prefix(event, type) when is_list(event) do
    [:skill_kit | event] ++ [type]
  end

  defp build_event_prefix(event, type) do
    build_event_prefix([event], type)
  end
end
