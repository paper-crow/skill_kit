defmodule SkillKit.Web.Components.ChatDrawer do
  use Phoenix.Component

  attr(:messages, :list, required: true)
  attr(:streaming_text, :string, default: nil)
  attr(:open, :boolean, default: false)

  def chat_drawer(assigns) do
    ~H"""
    <div class={[
      "h-full w-80 shrink-0 bg-editor-bg-alt border-l border-editor-border",
      "flex flex-col",
      if(@open, do: "", else: "hidden")
    ]}>
      <div class="px-3 py-2 border-b border-editor-border">
        <span class="text-xs font-medium text-editor-accent-muted uppercase tracking-wide">
          Chat
        </span>
      </div>

      <div class="flex-1 overflow-y-auto px-3 py-3 space-y-4">
        <.message :for={msg <- @messages} role={msg.role} content={msg.content} />
        <.streaming_message :if={@streaming_text} text={@streaming_text} />
      </div>

      <div class="border-t border-editor-border px-3 py-2">
        <form phx-submit="send_chat_message" class="flex gap-2">
          <input
            type="text"
            name="message"
            placeholder="Message"
            autocomplete="off"
            class="flex-1 bg-editor-bg border border-editor-border rounded px-2 py-1 text-sm text-editor-text placeholder-editor-text-faint focus:outline-none focus:border-editor-accent"
          />
          <button
            type="submit"
            class="text-xs text-editor-accent-muted hover:text-editor-accent transition-colors"
          >
            Send
          </button>
        </form>
      </div>
    </div>
    """
  end

  attr(:role, :atom, required: true)
  attr(:content, :string, required: true)

  defp message(%{role: :assistant} = assigns) do
    assigns = assign(assigns, :html, render_markdown(assigns.content))

    ~H"""
    <div>
      <div class="text-xs font-medium text-editor-accent mb-1">Assistant</div>
      <div class="prose-chat text-sm text-editor-text-muted">
        {Phoenix.HTML.raw(@html)}
      </div>
    </div>
    """
  end

  defp message(%{role: :user} = assigns) do
    ~H"""
    <div>
      <div class="text-xs font-medium text-editor-text-faint mb-1">You</div>
      <div class="text-sm text-editor-text-muted">{@content}</div>
    </div>
    """
  end

  attr(:text, :string, required: true)

  defp streaming_message(assigns) do
    assigns = assign(assigns, :html, render_markdown(assigns.text))

    ~H"""
    <div>
      <div class="text-xs font-medium text-editor-accent mb-1">Assistant</div>
      <div class="prose-chat text-sm text-editor-text-muted">
        {Phoenix.HTML.raw(@html)}<span class="inline-block w-1.5 h-3.5 bg-editor-accent animate-pulse ml-0.5 align-text-bottom" />
      </div>
    </div>
    """
  end

  defp render_markdown(text) do
    text
    |> Earmark.as_html!()
    |> String.trim()
  end
end
