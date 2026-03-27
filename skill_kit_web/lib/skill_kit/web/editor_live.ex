defmodule SkillKit.Web.EditorLive do
  use Phoenix.LiveView,
    layout: {SkillKit.Web.Layouts, :app}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full w-full">
      <div class="flex-1 flex items-center justify-center">
        <p class="text-editor-text-muted">Editor loading...</p>
      </div>
    </div>
    """
  end
end
