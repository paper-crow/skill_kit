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
    assigns = assign(assigns, :elements, parse_markdown(assigns.content))

    ~H"""
    <div class="flex-1 flex flex-col overflow-hidden">
      <div class="px-8 py-2 border-b border-editor-border">
        <span class="text-xs text-editor-accent-muted">{@path}</span>
      </div>
      <div class="flex-1 overflow-y-auto">
        <div
          id="editor-surface"
          class="max-w-editor mx-auto px-8 py-10 outline-none"
          contenteditable="true"
          phx-hook="MarkdownEditor"
          phx-debounce="500"
          data-path={@path}
        >
          <.render_element :for={element <- @elements} element={element} />
        </div>
      </div>
    </div>
    """
  end

  attr(:element, :any, required: true)

  defp render_element(%{element: {:h1, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <h1 class="font-heading text-2xl tracking-tight mb-4 text-editor-text">{@text}</h1>
    """
  end

  defp render_element(%{element: {:h2, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <h2 class="text-[11px] font-medium text-editor-accent-muted uppercase tracking-widest mt-8 mb-3">
      {@text}
    </h2>
    """
  end

  defp render_element(%{element: {:h3, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <h3 class="font-heading text-base mb-3 text-editor-text">{@text}</h3>
    """
  end

  defp render_element(%{element: {:divider}} = assigns) do
    ~H"""
    <hr class="border-editor-border my-6" />
    """
  end

  defp render_element(%{element: {:code, _lang, code_content}} = assigns) do
    assigns = assign(assigns, :code_content, code_content)

    ~H"""
    <pre class="bg-editor-accent-faint rounded p-4 my-4 font-mono text-sm text-editor-text overflow-x-auto"><code>{@code_content}</code></pre>
    """
  end

  defp render_element(%{element: {:empty}} = assigns) do
    ~H"""
    <div class="h-3"></div>
    """
  end

  defp render_element(%{element: {:paragraph, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <p class="text-sm text-editor-text-muted leading-[1.9] mb-3">{@text}</p>
    """
  end

  @doc """
  Parses a markdown string into a list of typed elements for rendering.

  Recognized element types:
  - `{:h1, text}` — lines starting with `# `
  - `{:h2, text}` — lines starting with `## `
  - `{:h3, text}` — lines starting with `### `
  - `{:divider}` — lines containing only `---`
  - `{:code, lang, content}` — fenced code blocks delimited by ` ``` `
  - `{:empty}` — blank lines
  - `{:paragraph, text}` — all other lines
  """
  def parse_markdown(content) do
    lines = String.split(content, "\n")
    {elements, _state} = Enum.reduce(lines, {[], :normal}, &parse_line/2)
    Enum.reverse(elements)
  end

  defp parse_line("```" <> lang, {acc, :normal}) do
    trimmed = String.trim(lang)
    {[{:code_open, trimmed, []} | acc], :code}
  end

  defp parse_line("```" <> _rest, {acc, :code}) do
    finalize_code_block(acc)
  end

  defp parse_line(line, {acc, :code}) do
    collect_code_line(line, acc)
  end

  defp parse_line("### " <> text, {acc, :normal}) do
    {[{:h3, text} | acc], :normal}
  end

  defp parse_line("## " <> text, {acc, :normal}) do
    {[{:h2, text} | acc], :normal}
  end

  defp parse_line("# " <> text, {acc, :normal}) do
    {[{:h1, text} | acc], :normal}
  end

  defp parse_line("---", {acc, :normal}) do
    {[{:divider} | acc], :normal}
  end

  defp parse_line("", {acc, :normal}) do
    {[{:empty} | acc], :normal}
  end

  defp parse_line(line, {acc, :normal}) do
    {[{:paragraph, line} | acc], :normal}
  end

  defp finalize_code_block([{:code_open, lang, lines} | rest]) do
    code_content = lines |> Enum.reverse() |> Enum.join("\n")
    {[{:code, lang, code_content} | rest], :normal}
  end

  defp collect_code_line(line, [{:code_open, lang, lines} | rest]) do
    {[{:code_open, lang, [line | lines]} | rest], :code}
  end
end
