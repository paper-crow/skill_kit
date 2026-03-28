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
      <div class="flex-1 overflow-y-auto scroll-smooth">
        <div
          id="editor-surface"
          class="max-w-editor mx-auto px-8 py-10 prose-editor"
          phx-hook="MarkdownEditor"
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

    content
    |> Earmark.as_html(options)
    |> add_heading_ids()
  end

  defp add_heading_ids({status, html, messages}) when status in [:ok, :error] do
    Regex.replace(~r/<(h[2-4])>(.*?)<\/\1>/s, html, fn _match, tag, text ->
      id = slugify(strip_html(text))
      ~s(<#{tag} id="#{id}">#{text}</#{tag}>)
    end)
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end

  defp strip_html(text) do
    Regex.replace(~r/<[^>]+>/, text, "")
  end
end
