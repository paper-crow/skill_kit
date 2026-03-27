defmodule SkillKit.TelemetryHelper do
  @moduledoc """
  Helper for testing telemetry events.

  ## Usage

  Include the helper in your test module:

      import SkillKit.TelemetryHelper

  Setup the telemetry handler:

      setup :telemetry

  Tag your tests with the telemetry events you want to listen for:

      @tag telemetry: [[:skill_kit, :turn, :stop]]
      test "it emits a telemetry event" do
        # ... trigger event ...
        assert_receive {__MODULE__, [:skill_kit, :turn, :stop], _metadata}
      end
  """

  @doc """
  Attaches a telemetry handler for the events specified in the `@tag telemetry: [...]` context.

  Events are forwarded to the test process as a tuple: `{module, event, metadata}`.
  """
  def telemetry(%{module: module, telemetry: events} = context) do
    :ok =
      SkillKit.Telemetry.attach_many(
        context.test,
        events,
        &__MODULE__.handle_telemetry/4,
        %{
          pid: self(),
          module: module
        }
      )

    ExUnit.Callbacks.on_exit(fn ->
      SkillKit.Telemetry.detach(context.test)
    end)
  end

  def telemetry(_), do: :ok

  @doc """
  Telemetry handler that forwards events to the test process.

  Events are forwarded as a tuple: `{module, event, metadata}`.
  """
  def handle_telemetry(event, _, metadata, %{pid: pid, module: module}) do
    send(pid, {module, event, metadata})
  end
end
