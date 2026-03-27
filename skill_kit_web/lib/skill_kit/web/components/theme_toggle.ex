defmodule SkillKit.Web.Components.ThemeToggle do
  use Phoenix.Component

  def theme_toggle(assigns) do
    ~H"""
    <button
      id="theme-toggle"
      phx-hook="Theme"
      class="w-8 h-8 rounded-lg flex items-center justify-center text-editor-text-faint hover:text-editor-text-muted transition-colors"
      title="Toggle theme"
    >
      <span class="dark:hidden">☾</span>
      <span class="hidden dark:inline">☀</span>
    </button>
    """
  end
end
