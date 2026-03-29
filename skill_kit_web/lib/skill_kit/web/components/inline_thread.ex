defmodule SkillKit.Web.Components.InlineThread do
  use Phoenix.Component

  attr(:thread, :map, default: nil)

  def inline_thread(%{thread: nil} = assigns) do
    ~H""
  end

  def inline_thread(assigns) do
    ~H"""
    <div
      id="inline-thread"
      phx-hook="InlineThread"
      class="fixed z-50 w-96 bg-editor-bg border border-editor-border rounded-xl shadow-2xl flex flex-col max-h-[500px] min-h-[200px]"
      style={"top: #{@thread.top}px; left: #{@thread.right + 12}px;"}
    >
      <div class="px-3 py-1.5 border-b border-editor-divider flex items-center justify-end">
        <button
          phx-click="close_inline_thread"
          class="text-editor-text-faint hover:text-editor-text-muted text-lg leading-none"
        >
          &times;
        </button>
      </div>

      <div class="flex-1 overflow-y-auto px-3 py-3 space-y-3">
        <div :for={msg <- @thread.messages}>
          <div :if={msg.role == :assistant} class="text-xs font-medium text-editor-accent mb-1">
            Assistant
          </div>
          <div :if={msg.role == :user} class="text-xs font-medium text-editor-text-faint mb-1">
            You
          </div>
          <div class="text-sm text-editor-text-muted">{msg.content}</div>
        </div>

        <div :if={@thread.streaming_text}>
          <div class="text-xs font-medium text-editor-accent mb-1">Assistant</div>
          <div class="text-sm text-editor-text-muted">
            {@thread.streaming_text}<span class="inline-block w-1 h-3 bg-editor-accent animate-pulse ml-0.5 align-text-bottom" />
          </div>
        </div>
      </div>

      <div class="px-3 py-2 border-t border-editor-divider">
        <form phx-submit="send_thread_message">
          <input
            type="text"
            name="message"
            placeholder="Reply..."
            autocomplete="off"
            class="w-full bg-transparent text-sm text-editor-text placeholder-editor-text-faint focus:outline-none"
          />
        </form>
      </div>
    </div>
    """
  end
end
