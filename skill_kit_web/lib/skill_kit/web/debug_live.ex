defmodule SkillKit.Web.DebugLive do
  use Phoenix.LiveView,
    layout: {SkillKit.Web.Layouts, :app}

  @max_events 500

  @telemetry_events [
    [:skill_kit, :tool_use, :start],
    [:skill_kit, :tool_use, :stop],
    [:skill_kit, :tool_use, :exception],
    [:skill_kit, :llm_request, :start],
    [:skill_kit, :llm_request, :stop],
    [:skill_kit, :llm_request, :exception],
    [:skill_kit, :agent, :start],
    [:skill_kit, :agent, :stop],
    [:skill_kit, :agent, :exception],
    [:skill_kit, :turn, :start],
    [:skill_kit, :turn, :stop],
    [:skill_kit, :turn, :exception],
    [:skill_kit, :skill_activation, :start],
    [:skill_kit, :skill_activation, :stop],
    [:skill_kit, :skill_activation, :exception],
    [:skill_kit, :subagent, :start],
    [:skill_kit, :subagent, :stop],
    [:skill_kit, :subagent, :exception],
    [:skill_kit, :conversation_save, :start],
    [:skill_kit, :conversation_save, :stop],
    [:skill_kit, :conversation_save, :exception],
    [:skill_kit, :conversation_load, :start],
    [:skill_kit, :conversation_load, :stop],
    [:skill_kit, :conversation_load, :exception],
    [:skill_kit, :llm, :rate_limited],
    [:skill_kit, :llm, :stream, :start],
    [:skill_kit, :llm, :stream, :stop],
    [:skill_kit, :llm, :stream, :exception],
    [:skill_kit, :llm, :stream, :error],
    [:skill_kit, :agent, :orphaned_result]
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      attach_telemetry_handlers()
    end

    socket =
      socket
      |> assign(:events, [])
      |> assign(:event_count, 0)
      |> assign(:paused, false)

    {:ok, socket}
  end

  @impl true
  def handle_info({:telemetry_event, event_name, measurements, metadata}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      event = build_event(event_name, measurements, metadata)
      events = Enum.take([event | socket.assigns.events], @max_events)
      count = socket.assigns.event_count + 1

      socket =
        socket
        |> assign(:events, events)
        |> assign(:event_count, count)

      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("clear", _params, socket) do
    socket =
      socket
      |> assign(:events, [])
      |> assign(:event_count, 0)

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    handler_id = handler_id()
    :telemetry.detach(handler_id)
  rescue
    _ -> :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full w-full bg-[#1a1b26] text-[#a9b1d6] font-mono text-sm">
      <div class="flex items-center justify-between px-4 py-2 border-b border-[#2a2b3d] bg-[#16161e]">
        <div class="flex items-center gap-3">
          <a
            href="/"
            class="text-[#565f89] hover:text-[#a9b1d6] transition-colors"
            title="Back to editor"
          >
            &larr;
          </a>
          <h1 class="text-[#c0caf5] font-semibold tracking-wide">Telemetry Debug</h1>
          <span class="text-[#565f89] text-xs">{@event_count} events</span>
        </div>
        <div class="flex items-center gap-2">
          <button
            phx-click="toggle_pause"
            class={[
              "px-3 py-1 rounded text-xs font-medium transition-colors",
              if(@paused,
                do: "bg-[#f7768e]/20 text-[#f7768e] hover:bg-[#f7768e]/30",
                else: "bg-[#2a2b3d] text-[#a9b1d6] hover:bg-[#33354a]"
              )
            ]}
          >
            {if @paused, do: "Resume", else: "Pause"}
          </button>
          <button
            phx-click="clear"
            class="px-3 py-1 rounded text-xs font-medium bg-[#2a2b3d] text-[#a9b1d6] hover:bg-[#33354a] transition-colors"
          >
            Clear
          </button>
        </div>
      </div>

      <div
        id="event-log"
        phx-hook="AutoScroll"
        class="flex-1 overflow-y-auto px-4 py-2 space-y-0"
      >
        <div :if={@events == []} class="text-[#565f89] text-center py-12">
          Waiting for telemetry events...
        </div>
        <div
          :for={event <- Enum.reverse(@events)}
          class="flex items-baseline gap-3 py-0.5 hover:bg-[#1e1f2e] rounded px-1"
        >
          <span class="text-[#565f89] text-xs shrink-0">{event.timestamp}</span>
          <span class={[
            "text-xs font-semibold px-1.5 py-0.5 rounded shrink-0",
            badge_class(event.category)
          ]}>
            {event.label}
          </span>
          <span :if={event.duration} class="text-[#bb9af7] text-xs shrink-0">
            {event.duration}
          </span>
          <span class="text-[#7aa2f7] text-xs truncate">{event.detail}</span>
        </div>
      </div>

      <div
        :if={@paused}
        class="px-4 py-1.5 bg-[#f7768e]/10 border-t border-[#f7768e]/20 text-center text-[#f7768e] text-xs"
      >
        Paused
      </div>
    </div>
    """
  end

  # -- Private ---------------------------------------------------------------

  @doc false
  def handle_telemetry_event(event_name, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp attach_telemetry_handlers do
    :telemetry.attach_many(
      handler_id(),
      @telemetry_events,
      &__MODULE__.handle_telemetry_event/4,
      self()
    )
  end

  defp handler_id do
    "debug-live-#{inspect(self())}"
  end

  defp build_event(event_name, measurements, metadata) do
    %{
      timestamp: format_time(),
      label: format_label(event_name),
      category: categorize(event_name),
      duration: format_duration(measurements),
      detail: format_detail(event_name, measurements, metadata)
    }
  end

  defp format_time do
    now = DateTime.utc_now()
    {microseconds, _precision} = now.microsecond
    ms = div(microseconds, 1000)

    [now.hour, now.minute, now.second]
    |> Enum.map_join(":", &pad_two/1)
    |> Kernel.<>(".#{pad_three(ms)}")
  end

  defp pad_two(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
  defp pad_three(n), do: String.pad_leading(Integer.to_string(n), 3, "0")

  defp format_label(event_name) do
    event_name
    |> Enum.drop(1)
    |> Enum.map_join(":", &upcase_atom/1)
  end

  defp upcase_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.upcase()
  end

  defp categorize(event_name) do
    case Enum.at(event_name, 1) do
      :tool_use -> :tool
      :llm_request -> :llm
      :llm -> :llm
      :agent -> :agent
      :turn -> :turn
      :skill_activation -> :skill
      :subagent -> :agent
      :conversation_save -> :storage
      :conversation_load -> :storage
      _ -> :default
    end
  end

  defp badge_class(:tool), do: "bg-[#7aa2f7]/20 text-[#7aa2f7]"
  defp badge_class(:llm), do: "bg-[#bb9af7]/20 text-[#bb9af7]"
  defp badge_class(:agent), do: "bg-[#9ece6a]/20 text-[#9ece6a]"
  defp badge_class(:turn), do: "bg-[#e0af68]/20 text-[#e0af68]"
  defp badge_class(:skill), do: "bg-[#2ac3de]/20 text-[#2ac3de]"
  defp badge_class(:storage), do: "bg-[#73daca]/20 text-[#73daca]"
  defp badge_class(:error), do: "bg-[#f7768e]/20 text-[#f7768e]"
  defp badge_class(_), do: "bg-[#565f89]/20 text-[#565f89]"

  defp format_duration(%{duration: duration}) when is_integer(duration) do
    ms = System.convert_time_unit(duration, :native, :millisecond)
    "#{ms}ms"
  end

  defp format_duration(_), do: nil

  defp format_detail(event_name, measurements, metadata) do
    parts = event_specific_detail(event_name, measurements, metadata)
    extra = generic_metadata_detail(metadata)
    Enum.join(parts ++ extra, "  ")
  end

  defp event_specific_detail([:skill_kit, :tool_use | _], _m, meta) do
    tool_name = Map.get(meta, :tool_name) || Map.get(meta, :tool)
    build_kv_list([{"tool", tool_name}])
  end

  defp event_specific_detail([:skill_kit, :llm_request | _], measurements, meta) do
    model = Map.get(meta, :model)
    input = Map.get(measurements, :input_tokens) || Map.get(meta, :input_tokens)
    output = Map.get(measurements, :output_tokens) || Map.get(meta, :output_tokens)
    build_kv_list([{"model", model}, {"tokens_in", input}, {"tokens_out", output}])
  end

  defp event_specific_detail([:skill_kit, :llm | _], _m, meta) do
    model = Map.get(meta, :model)
    error = Map.get(meta, :error)
    build_kv_list([{"model", model}, {"error", error}])
  end

  defp event_specific_detail([:skill_kit, :agent | _], _m, meta) do
    agent = Map.get(meta, :agent_name) || Map.get(meta, :name)
    build_kv_list([{"agent", agent}])
  end

  defp event_specific_detail([:skill_kit, :skill_activation | _], _m, meta) do
    skill = Map.get(meta, :skill_name) || Map.get(meta, :skill)
    build_kv_list([{"skill", skill}])
  end

  defp event_specific_detail([:skill_kit, :subagent | _], _m, meta) do
    name = Map.get(meta, :name) || Map.get(meta, :agent_name)
    build_kv_list([{"subagent", name}])
  end

  defp event_specific_detail([:skill_kit, :turn | _], _m, meta) do
    status = Map.get(meta, :status)
    build_kv_list([{"status", status}])
  end

  defp event_specific_detail(_, _m, _meta), do: []

  defp generic_metadata_detail(metadata) do
    metadata
    |> Map.drop([
      :tool_name,
      :tool,
      :model,
      :agent_name,
      :name,
      :skill_name,
      :skill,
      :status,
      :input_tokens,
      :output_tokens,
      :error,
      :kind,
      :reason,
      :stacktrace
    ])
    |> Enum.take(3)
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v, limit: 50, printable_limit: 100)}" end)
  end

  defp build_kv_list(pairs) do
    pairs
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> "#{k}=#{format_value(v)}" end)
  end

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_atom(v), do: Atom.to_string(v)
  defp format_value(v), do: inspect(v, limit: 50, printable_limit: 100)
end
