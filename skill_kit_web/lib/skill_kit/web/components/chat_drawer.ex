defmodule SkillKit.Web.Components.ChatDrawer do
  use Phoenix.Component

  attr(:messages, :list, required: true)
  attr(:streaming_text, :string, default: nil)
  attr(:open, :boolean, default: false)

  def chat_drawer(assigns) do
    ~H"""
    <div class={[
      "h-full w-[420px] shrink-0 bg-editor-bg border-l border-editor-divider",
      "flex flex-col",
      if(@open, do: "", else: "hidden")
    ]}>
      <div class="flex-1 overflow-y-auto px-4 py-4 space-y-5">
        <.message :for={msg <- @messages} role={msg.role} content={msg.content} />
        <.streaming_message :if={@streaming_text} text={@streaming_text} />
      </div>

      <div class="px-3 py-3">
        <form phx-submit="send_chat_message" class="relative">
          <textarea
            name="message"
            placeholder="Type your message..."
            rows="3"
            autocomplete="off"
            phx-keydown="chat_keydown"
            phx-key="Enter"
            class="w-full bg-editor-bg border border-editor-border rounded-xl px-4 py-3 pr-14
                   text-sm text-editor-text placeholder-editor-text-faint
                   focus:outline-none focus:border-editor-accent-muted
                   resize-none"
          />
          <button
            type="submit"
            class="absolute bottom-3 right-3 w-8 h-8 rounded-full
                   bg-editor-accent text-white
                   flex items-center justify-center
                   hover:opacity-90 transition-opacity"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 20 20"
              fill="currentColor"
              class="w-4 h-4"
            >
              <path
                fill-rule="evenodd"
                d="M10 17a.75.75 0 01-.75-.75V5.612L5.29 9.77a.75.75 0 01-1.08-1.04l5.25-5.5a.75.75 0 011.08 0l5.25 5.5a.75.75 0 11-1.08 1.04l-3.96-4.158V16.25A.75.75 0 0110 17z"
                clip-rule="evenodd"
              />
            </svg>
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
      <div class="text-sm font-medium text-editor-accent mb-1.5">Assistant</div>
      <div class="prose-chat text-[15px] text-editor-text-muted">
        {Phoenix.HTML.raw(@html)}
      </div>
    </div>
    """
  end

  defp message(%{role: :user} = assigns) do
    ~H"""
    <div>
      <div class="text-sm font-medium text-editor-text-faint mb-1.5">You</div>
      <div class="text-[15px] text-editor-text-muted">{@content}</div>
    </div>
    """
  end

  attr(:text, :string, required: true)

  defp streaming_message(assigns) do
    assigns = assign(assigns, :html, render_markdown(assigns.text))

    ~H"""
    <div>
      <div class="text-sm font-medium text-editor-accent mb-1.5">Assistant</div>
      <div class="prose-chat text-[15px] text-editor-text-muted">
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
