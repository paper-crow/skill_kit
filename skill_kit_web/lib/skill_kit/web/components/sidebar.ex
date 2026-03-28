defmodule SkillKit.Web.Components.Sidebar do
  use Phoenix.Component

  attr(:active, :atom, default: nil)

  def sidebar(assigns) do
    ~H"""
    <nav class="w-12 bg-editor-bg-alt border-r border-editor-border flex flex-col items-center pt-4 gap-1.5">
      <.icon_button
        icon="document"
        label="Documents"
        panel={:docs}
        active={@active == :docs}
      />
      <.icon_button
        icon="chat"
        label="Chat"
        panel={:chat}
        active={@active == :chat}
      />
      <.icon_button
        icon="build"
        label="Build"
        panel={:build}
        active={@active == :build}
      />
      <div class="mt-auto mb-4">
        <.icon_button
          icon="app"
          label="App"
          panel={:app}
          active={false}
        />
      </div>
    </nav>
    """
  end

  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:panel, :atom, required: true)
  attr(:active, :boolean, default: false)

  defp icon_button(assigns) do
    ~H"""
    <button
      phx-click="toggle_drawer"
      phx-value-panel={@panel}
      title={@label}
      class={[
        "w-8 h-8 rounded-lg flex items-center justify-center text-sm transition-colors",
        if(@active,
          do: "bg-editor-accent-faint text-editor-accent shadow-[0_0_0_1px] shadow-editor-accent/20",
          else: "text-editor-text-faint hover:text-editor-text-muted hover:bg-editor-accent-faint/50"
        )
      ]}
    >
      <span class="sr-only">{@label}</span>
      {icon_char(@icon)}
    </button>
    """
  end

  defp icon_char("document"), do: "☰"
  defp icon_char("chat"), do: "✎"
  defp icon_char("build"), do: "⚙"
  defp icon_char("app"), do: "▶"
end
