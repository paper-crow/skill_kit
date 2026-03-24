defmodule SkillKit.Telemetry do
  @moduledoc """
  Telemetry integration for SkillKit.

  All events are prefixed with `[:skill_kit]`. Unless specified,
  all times are in `:native` units.

  ## Agent events

  - `[:skill_kit, :agent, :turn_start, :start]`
  - `[:skill_kit, :agent, :turn_start, :stop]`
  - `[:skill_kit, :agent, :usage]`
  - `[:skill_kit, :agent, :response]`
  - `[:skill_kit, :agent, :error]`
  - `[:skill_kit, :agent, :tool_call]`
  - `[:skill_kit, :agent, :tool_result]`
  - `[:skill_kit, :agent, :subagent_result]`
  - `[:skill_kit, :agent, :orphaned_result]`

  ## LLM events

  - `[:skill_kit, :llm, :rate_limited]`
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
