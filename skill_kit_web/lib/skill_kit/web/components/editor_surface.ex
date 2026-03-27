defmodule SkillKit.Web.Components.EditorSurface do
  use Phoenix.Component

  attr(:content, :string, default: nil)
  attr(:path, :string, default: nil)
  attr(:threads, :list, default: [])

  def editor_surface(%{content: nil} = assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center text-editor-text-faint text-sm">
      No document open
    </div>
    """
  end

  def editor_surface(assigns) do
    assigns = assign(assigns, :rendered_html, render_markdown(assigns.content))

    ~H"""
    <div class="flex-1 flex flex-col overflow-hidden">
      <div class="flex-1 overflow-y-auto">
        <div
          id="editor-surface"
          class="max-w-editor mx-auto px-8 py-10 outline-none prose-editor"
          contenteditable="true"
          spellcheck="false"
          phx-hook="MarkdownEditor"
          phx-debounce="500"
          data-path={@path}
        >
          {Phoenix.HTML.raw(@rendered_html)}
        </div>
      </div>
    </div>
    """
  end

  defp render_markdown(content) do
    options = %Earmark.Options{code_class_prefix: "language-"}

    case Earmark.as_html(content, options) do
      {:ok, html, _warnings} -> html
      {:error, html, _errors} -> html
    end
  end
end
