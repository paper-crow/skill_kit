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

  @doc """
  Executes a `<prefix>:start` telemetry event and returns the monotonic start time.

  `event` is a list of atoms appended to `[:anthropic]` (e.g. `[:request]`).
  `meta` is the metadata map forwarded to `:telemetry.execute/3`.
  `extra_measurements` are merged with the `:system_time` measurement.
  """
  @spec start(list(atom()) | atom(), map(), map()) :: integer()
  def start(event, meta \\ %{}, extra_measurements \\ %{}) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      build_event_prefix(event, :start),
      Map.put(extra_measurements, :system_time, System.system_time()),
      meta
    )

    start_time
  end

  @doc """
  Executes a `<prefix>:stop` telemetry event, measuring duration since `start_time`.

  `start_time` should be the value returned by `start/3`.
  `extra_measurements` are merged with the computed `:duration`.
  """
  @spec stop(list(atom()) | atom(), integer(), map(), map()) :: :ok
  def stop(event, start_time, meta \\ %{}, extra_measurements \\ %{}) do
    end_time = System.monotonic_time()
    measurements = Map.put(extra_measurements, :duration, end_time - start_time)

    :telemetry.execute(
      build_event_prefix(event, :stop),
      measurements,
      meta
    )
  end

  @doc """
  Executes a point-in-time telemetry event (no start/stop pairing).

  `event` is a list of atoms appended to `[:anthropic]`.
  """
  @spec event(list(atom()) | atom(), map(), map()) :: :ok
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
