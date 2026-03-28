defmodule SkillKit.Web.Components.DebugPanel do
  use Phoenix.Component

  attr(:events, :list, required: true)
  attr(:event_count, :integer, default: 0)
  attr(:paused, :boolean, default: false)
  attr(:open, :boolean, default: false)

  def debug_panel(assigns) do
    ~H"""
    <div class={[
      "h-full w-80 shrink-0 bg-editor-bg-alt border-l border-editor-border",
      "flex flex-col font-mono text-sm",
      if(@open, do: "", else: "hidden")
    ]}>
      <div class="flex items-center justify-between px-3 py-2 border-b border-editor-border">
        <div class="flex items-center gap-2">
          <span class="text-xs font-medium text-editor-accent-muted uppercase tracking-wide">
            Build
          </span>
          <span class="text-editor-text-faint text-xs">{@event_count} events</span>
        </div>
        <div class="flex items-center gap-1">
          <button
            phx-click="toggle_debug_pause"
            class={[
              "px-2 py-0.5 rounded text-xs font-medium transition-colors",
              if(@paused,
                do: "bg-[#f7768e]/20 text-[#f7768e] hover:bg-[#f7768e]/30",
                else:
                  "text-editor-text-faint hover:text-editor-text-muted hover:bg-editor-accent-faint/50"
              )
            ]}
          >
            {if @paused, do: "Resume", else: "Pause"}
          </button>
          <button
            phx-click="clear_debug_events"
            class="px-2 py-0.5 rounded text-xs font-medium text-editor-text-faint hover:text-editor-text-muted hover:bg-editor-accent-faint/50 transition-colors"
          >
            Clear
          </button>
          <button
            phx-click="toggle_drawer"
            phx-value-panel="build"
            class="w-5 h-5 rounded flex items-center justify-center text-editor-accent-muted hover:text-editor-accent hover:bg-editor-accent-faint/50 transition-colors"
            title="Close build panel"
          >
            &times;
          </button>
        </div>
      </div>

      <div
        id="debug-event-log"
        phx-hook="AutoScroll"
        class="flex-1 overflow-y-auto px-3 py-2 space-y-0"
      >
        <div :if={@events == []} class="text-editor-text-faint text-center py-12 text-xs">
          Waiting for telemetry events...
        </div>
        <div
          :for={event <- Enum.reverse(@events)}
          class="flex items-baseline gap-2 py-0.5 hover:bg-editor-accent-faint/30 rounded px-1"
        >
          <span class="text-editor-text-faint text-xs shrink-0">{event.timestamp}</span>
          <span class={[
            "text-xs font-semibold px-1 py-0.5 rounded shrink-0",
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
        class="px-3 py-1 bg-[#f7768e]/10 border-t border-[#f7768e]/20 text-center text-[#f7768e] text-xs"
      >
        Paused
      </div>
    </div>
    """
  end

  defp badge_class(:tool), do: "bg-[#7aa2f7]/20 text-[#7aa2f7]"
  defp badge_class(:llm), do: "bg-[#bb9af7]/20 text-[#bb9af7]"
  defp badge_class(:agent), do: "bg-[#9ece6a]/20 text-[#9ece6a]"
  defp badge_class(:turn), do: "bg-[#e0af68]/20 text-[#e0af68]"
  defp badge_class(:skill), do: "bg-[#2ac3de]/20 text-[#2ac3de]"
  defp badge_class(:storage), do: "bg-[#73daca]/20 text-[#73daca]"
  defp badge_class(:error), do: "bg-[#f7768e]/20 text-[#f7768e]"
  defp badge_class(_), do: "bg-[#565f89]/20 text-[#565f89]"
end
