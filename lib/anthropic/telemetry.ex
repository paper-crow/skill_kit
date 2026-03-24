defmodule Anthropic.Telemetry do
  @moduledoc """
  Telemetry integration for the Anthropic client.

  All events are prefixed with `[:anthropic]`.

  ## Events

  - `[:anthropic, :request, :start]` — before an API request
  - `[:anthropic, :request, :stop]` — after a successful API request
  - `[:anthropic, :request, :exception]` — on request failure
  - `[:anthropic, :rate_limited]` — when a 429 triggers a retry
  """

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
  def event(event, measurements, meta) do
    :telemetry.execute(build_event_prefix(event), measurements, meta)
  end

  defp build_event_prefix(event, type \\ nil)

  defp build_event_prefix(event, nil) when is_list(event) do
    [:anthropic | event]
  end

  defp build_event_prefix(event, type) when is_list(event) do
    [:anthropic | event] ++ [type]
  end

  defp build_event_prefix(event, type) do
    build_event_prefix([event], type)
  end
end
