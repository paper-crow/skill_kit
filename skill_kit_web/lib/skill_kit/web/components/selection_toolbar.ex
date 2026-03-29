defmodule SkillKit.Web.Components.SelectionToolbar do
  use Phoenix.Component

  attr(:selection, :map, default: nil)

  def selection_toolbar(%{selection: nil} = assigns) do
    ~H""
  end

  def selection_toolbar(assigns) do
    ~H"""
    <div
      id="selection-toolbar"
      class="fixed z-40 bg-editor-bg-alt border border-editor-border rounded-lg shadow-lg px-2 py-1"
      style={"top: #{@selection.top - 40}px; left: #{@selection.left}px;"}
    >
      <button
        phx-click="open_inline_thread"
        class="text-sm text-editor-accent-muted hover:text-editor-accent transition-colors px-2 py-1"
      >
        Ask agent
      </button>
    </div>
    """
  end
end
