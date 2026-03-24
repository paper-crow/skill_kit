defmodule SkillKit.Telemetry.Handler do
  @moduledoc """
  A behaviour and macro for creating event handlers that subscribe to telemetry events.

  ## Usage

      defmodule MyApp.Handlers.AgentLogger do
        use SkillKit.Telemetry.Handler, events: [
          [:skill_kit, :agent, :turn, :stop]
        ]

        @impl true
        def handle_event([:skill_kit, :agent, :turn, :stop], measurements, metadata) do
          Logger.info("Turn completed in \#{measurements.duration}ns for \#{metadata.agent_name}")
          :ok
        end
      end

  The handler module becomes a GenServer that:
  - Subscribes to the specified telemetry events on startup
  - Calls `handle_event/3` when events are emitted
  - Can be added to a supervision tree
  """

  @callback handle_event(event :: list(), measurements :: map(), metadata :: map()) :: any()

  defmacro __using__(opts) do
    events = Keyword.get(opts, :events, [])
    first_event = List.first(events) || []

    quote bind_quoted: [events: events, first_event: first_event] do
      @behaviour SkillKit.Telemetry.Handler
      use GenServer

      @events events
      @handler_name __MODULE__
                    |> Module.split()
                    |> List.last()
                    |> Macro.underscore()
                    |> String.to_atom()

      event_list = "[:" <> Enum.join(first_event, ", :") <> "]"

      @doc """
      Starts the handler and subscribes to telemetry events.

      ## Examples

          iex> {:ok, pid} = #{inspect(__MODULE__)}.start_link()
          iex> Process.alive?(pid)
          true
          iex> :telemetry.list_handlers(#{event_list})
          ...> |> Enum.any?(&(&1.id == #{inspect(__MODULE__)}))
          true
          iex> GenServer.stop(pid)
          :ok
      """
      def start_link(args \\ []) do
        GenServer.start_link(__MODULE__, args, name: __MODULE__)
      end

      def init(_args) do
        :telemetry.detach(__MODULE__)

        SkillKit.Telemetry.attach_many(
          __MODULE__,
          @events,
          &__MODULE__.__handle_telemetry_event__/4,
          self()
        )

        {:ok, %{events: @events}}
      end

      def handle_info({event, measurements, metadata}, state) do
        span_metadata = Map.merge(metadata, %{event: event})

        SkillKit.Telemetry.span([@handler_name], span_metadata, fn ->
          handle_event(event, measurements, metadata)
          {:ok, %{}}
        end)

        {:noreply, state}
      end

      def terminate(_reason, _state) do
        :telemetry.detach(__MODULE__)
        :ok
      end

      def __handle_telemetry_event__(event, measurements, metadata, pid) do
        send(pid, {event, measurements, metadata})
      end
    end
  end
end
