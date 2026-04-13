defmodule SkillKit.Web.Components.DebugPanel do
  use Phoenix.Component

  attr(:events, :list, required: true)
  attr(:event_count, :integer, default: 0)
  attr(:paused, :boolean, default: false)
  attr(:open, :boolean, default: false)

  def debug_panel(assigns) do
    ~H"""
    <div
      :if={@open}
      class="absolute bottom-12 right-4 w-[600px] h-[360px] z-30 rounded-lg border border-editor-border bg-[#1a1b26] shadow-2xl flex flex-col font-mono text-xs overflow-hidden"
    >
      <div class="flex items-center justify-between px-3 py-2 border-b border-white/10 bg-[#16161e]">
        <div class="flex items-center gap-3">
          <span class="text-[10px] font-semibold text-white/40 uppercase tracking-widest">
            Telemetry
          </span>
          <span class="text-white/20">{@event_count} events</span>
        </div>
        <div class="flex items-center gap-1">
          <button
            phx-click="toggle_debug_pause"
            class={[
              "px-2 py-0.5 rounded text-[10px] font-medium transition-colors",
              if(@paused,
                do: "bg-[#f7768e]/20 text-[#f7768e]",
                else: "text-white/30 hover:text-white/50 hover:bg-white/5"
              )
            ]}
          >
            {if @paused, do: "Resume", else: "Pause"}
          </button>
          <button
            phx-click="clear_debug_events"
            class="px-2 py-0.5 rounded text-[10px] font-medium text-white/30 hover:text-white/50 hover:bg-white/5 transition-colors"
          >
            Clear
          </button>
          <button
            phx-click="toggle_drawer"
            phx-value-panel="build"
            class="ml-1 w-5 h-5 rounded flex items-center justify-center text-white/30 hover:text-white/60 hover:bg-white/5 transition-colors"
          >
            &times;
          </button>
        </div>
      </div>

      <div
        id="debug-event-log"
        phx-hook="AutoScroll"
        class="flex-1 overflow-y-auto px-2 py-1"
      >
        <div :if={@events == []} class="text-white/20 text-center py-16">
          Waiting for events...
        </div>
        <div
          :for={event <- Enum.reverse(@events)}
          class="flex items-baseline gap-2 py-[3px] px-1 hover:bg-white/[0.03] rounded"
        >
          <span class="text-white/20 shrink-0">{event.timestamp}</span>
          <span class={["font-semibold px-1.5 py-[1px] rounded shrink-0", badge_class(event.category)]}>
            {event.label}
          </span>
          <span :if={event.duration} class="text-[#bb9af7] shrink-0">
            {event.duration}
          </span>
          <span class="text-[#7aa2f7]/70 truncate">{event.detail}</span>
        </div>
      </div>

      <div
        :if={@paused}
        class="px-3 py-1 bg-[#f7768e]/10 border-t border-[#f7768e]/20 text-center text-[#f7768e]"
      >
        Paused
      </div>
    </div>
    """
  end

  defp badge_class(:tool), do: "bg-[#7aa2f7]/15 text-[#7aa2f7]"
  defp badge_class(:llm), do: "bg-[#bb9af7]/15 text-[#bb9af7]"
  defp badge_class(:agent), do: "bg-[#9ece6a]/15 text-[#9ece6a]"
  defp badge_class(:turn), do: "bg-[#e0af68]/15 text-[#e0af68]"
  defp badge_class(:skill), do: "bg-[#2ac3de]/15 text-[#2ac3de]"
  defp badge_class(:storage), do: "bg-[#73daca]/15 text-[#73daca]"
  defp badge_class(:error), do: "bg-[#f7768e]/15 text-[#f7768e]"
  defp badge_class(_), do: "bg-white/10 text-white/30"
end
