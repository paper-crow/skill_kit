defmodule SkillKit.Web.Components.DocumentTree do
  use Phoenix.Component

  attr(:files, :list, required: true)
  attr(:current_path, :string, default: nil)
  attr(:open, :boolean, default: false)

  def document_tree(assigns) do
    ~H"""
    <div class={[
      "h-full w-64 shrink-0 bg-editor-bg-alt border-r border-editor-border",
      "flex flex-col",
      unless(@open, do: "hidden")
    ]}>
      <nav class="flex-1 overflow-y-auto py-3">
        <.doc_entry
          :for={file <- @files}
          file={file}
          active={file.path == @current_path}
        />
      </nav>
      <div class="px-3 py-2 border-t border-editor-border flex items-center gap-2">
        <button
          phx-click="toggle_drawer"
          phx-value-panel="build"
          class="text-editor-text-faint hover:text-editor-accent-muted text-sm transition-colors"
          title="Telemetry"
        >
          &#9881;
        </button>
        <button
          id="theme-toggle"
          phx-hook="Theme"
          class="text-editor-text-faint hover:text-editor-accent-muted text-sm transition-colors"
          title="Toggle theme"
        >
          <span class="dark:hidden">&#9790;</span>
          <span class="hidden dark:inline">&#9728;</span>
        </button>
      </div>
    </div>
    """
  end

  attr(:file, :map, required: true)
  attr(:active, :boolean, default: false)

  defp doc_entry(assigns) do
    headings = Map.get(assigns.file, :headings, [])
    assigns = assign(assigns, :headings, headings)

    ~H"""
    <div class="mb-0.5">
      <button
        phx-click="open_document"
        phx-value-path={@file.path}
        class={[
          "w-full text-left px-3 py-1.5 text-base font-medium truncate transition-colors",
          if(@active,
            do: "text-editor-accent",
            else: "text-editor-text-muted hover:text-editor-text"
          )
        ]}
      >
        {@file.title}
      </button>
      <div :if={@active and @headings != []} class="ml-3 border-l border-editor-divider">
        <button
          :for={heading <- @headings}
          phx-click="scroll_to_heading"
          phx-value-heading={heading}
          class="block w-full text-left px-3 py-0.5 text-sm text-editor-text-faint hover:text-editor-accent-muted truncate transition-colors"
        >
          {heading}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Converts a flat list of file entries into a nested tree structure.
  """
  def build_tree(entries) do
    grouped = Enum.group_by(entries, &entry_prefix/1)
    root_files = Map.get(grouped, :root, [])
    dirs = Map.drop(grouped, [:root])

    root_nodes = Enum.map(root_files, &file_node/1)
    dir_nodes = dirs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&dir_node/1)

    root_nodes ++ dir_nodes
  end

  defp entry_prefix(%{path: path}) do
    case Path.split(path) do
      [_file] -> :root
      [dir | _rest] -> dir
    end
  end

  defp file_node(%{path: path, title: title}) do
    %{type: :file, name: Path.basename(path), title: title, path: path}
  end

  defp dir_node({dir, entries}) do
    children = Enum.map(entries, &file_node/1)
    %{type: :directory, name: dir, children: children}
  end
end
