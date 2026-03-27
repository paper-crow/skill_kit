defmodule SkillKit.Web.Components.EditorSurface do
  use Phoenix.Component

  alias Phoenix.HTML

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
    assigns = assign(assigns, :inline, render_inline(text))

    ~H"""
    <h1 class="font-heading text-2xl tracking-tight mb-4 text-editor-text">{@inline}</h1>
    """
  end

  defp render_element(%{element: {:h2, text}} = assigns) do
    assigns = assign(assigns, :inline, render_inline(text))

    ~H"""
    <h2 class="text-[11px] font-medium text-editor-accent-muted uppercase tracking-widest mt-8 mb-3">
      {@inline}
    </h2>
    """
  end

  defp render_element(%{element: {:h3, text}} = assigns) do
    assigns = assign(assigns, :inline, render_inline(text))

    ~H"""
    <h3 class="font-heading text-base mb-3 text-editor-text">{@inline}</h3>
    """
  end

  defp render_element(%{element: {:divider}} = assigns) do
    ~H"""
    <hr class="border-editor-border my-6" />
    """
  end

  defp render_element(%{element: {:code, lang, code_content}} = assigns) do
    assigns =
      assigns
      |> assign(:code_content, code_content)
      |> assign(:lang_class, code_language_class(lang))

    ~H"""
    <pre class="bg-editor-accent-faint rounded p-4 my-4 font-mono text-sm text-editor-text overflow-x-auto"><code class={@lang_class}>{@code_content}</code></pre>
    """
  end

  defp render_element(%{element: {:empty}} = assigns) do
    ~H"""
    <div class="h-3"></div>
    """
  end

  defp render_element(%{element: {:paragraph, text}} = assigns) do
    assigns = assign(assigns, :inline, render_inline(text))

    ~H"""
    <p class="text-sm text-editor-text-muted leading-[1.9] mb-3">{@inline}</p>
    """
  end

  defp render_element(%{element: {:ul, items}} = assigns) do
    assigns = assign(assigns, :items, Enum.map(items, &render_inline/1))

    ~H"""
    <ul class="list-disc pl-6 mb-3 space-y-1">
      <li :for={item <- @items} class="text-sm text-editor-text-muted leading-[1.9]">{item}</li>
    </ul>
    """
  end

  defp render_element(%{element: {:ol, items}} = assigns) do
    assigns = assign(assigns, :items, Enum.map(items, &render_inline/1))

    ~H"""
    <ol class="list-decimal pl-6 mb-3 space-y-1">
      <li :for={item <- @items} class="text-sm text-editor-text-muted leading-[1.9]">{item}</li>
    </ol>
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

    elements
    |> Enum.reverse()
    |> coalesce_lists()
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

  defp parse_line("- " <> text, {acc, :normal}) do
    {[{:ul_item, text} | acc], :normal}
  end

  defp parse_line("* " <> text, {acc, :normal}) do
    {[{:ul_item, text} | acc], :normal}
  end

  defp parse_line(line, {acc, :normal}) do
    case Regex.run(~r/^(\d+)\.\s+(.*)$/, line) do
      [_, _num, text] -> {[{:ol_item, text} | acc], :normal}
      nil -> {[{:paragraph, line} | acc], :normal}
    end
  end

  defp finalize_code_block([{:code_open, lang, lines} | rest]) do
    code_content = lines |> Enum.reverse() |> Enum.join("\n")
    {[{:code, lang, code_content} | rest], :normal}
  end

  defp collect_code_line(line, [{:code_open, lang, lines} | rest]) do
    {[{:code_open, lang, [line | lines]} | rest], :code}
  end

  defp coalesce_lists(elements) do
    elements
    |> Enum.chunk_by(&list_type/1)
    |> Enum.flat_map(&merge_list_chunk/1)
  end

  defp list_type({:ul_item, _}), do: :ul
  defp list_type({:ol_item, _}), do: :ol
  defp list_type(_other), do: :other

  defp merge_list_chunk([{:ul_item, _} | _] = chunk) do
    items = Enum.map(chunk, &elem(&1, 1))
    [{:ul, items}]
  end

  defp merge_list_chunk([{:ol_item, _} | _] = chunk) do
    items = Enum.map(chunk, &elem(&1, 1))
    [{:ol, items}]
  end

  defp merge_list_chunk(chunk), do: chunk

  defp code_language_class(""), do: nil
  defp code_language_class(lang), do: "language-#{lang}"

  @doc """
  Renders inline markdown (bold, italic, code, links) into Phoenix.HTML safe markup.
  """
  def render_inline(text) do
    text
    |> escape_html()
    |> parse_inline_code()
    |> parse_bold()
    |> parse_italic()
    |> parse_links()
    |> HTML.raw()
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp parse_inline_code(text) do
    Regex.replace(~r/`([^`]+)`/, text, fn _match, code ->
      ~s(<code class="font-mono text-xs bg-editor-accent-faint px-1 py-0.5 rounded">#{code}</code>)
    end)
  end

  defp parse_bold(text) do
    text
    |> replace_bold(~r/\*\*(.+?)\*\*/)
    |> replace_bold(~r/__(.+?)__/)
  end

  defp replace_bold(text, pattern) do
    Regex.replace(pattern, text, "<strong>\\1</strong>")
  end

  defp parse_italic(text) do
    text
    |> replace_italic(~r/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/)
    |> replace_italic(~r/(?<!_)_(?!_)(.+?)(?<!_)_(?!_)/)
  end

  defp replace_italic(text, pattern) do
    Regex.replace(pattern, text, "<em>\\1</em>")
  end

  defp parse_links(text) do
    Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, text, fn _match, label, url ->
      ~s(<a href="#{url}" class="text-editor-accent hover:underline">#{label}</a>)
    end)
  end
end
