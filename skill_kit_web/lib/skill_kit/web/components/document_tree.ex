defmodule SkillKit.Web.Components.DocumentTree do
  use Phoenix.Component

  attr(:files, :list, required: true)
  attr(:current_path, :string, default: nil)
  attr(:open, :boolean, default: false)

  def document_tree(assigns) do
    assigns = assign(assigns, :tree, build_tree(assigns.files))

    ~H"""
    <div class={[
      "absolute top-0 left-12 h-full w-56 bg-editor-bg-alt border-r border-editor-border",
      "flex flex-col z-10",
      if(@open, do: "", else: "hidden")
    ]}>
      <div class="flex items-center justify-between px-3 py-2 border-b border-editor-border">
        <span class="text-xs font-medium text-editor-accent-muted uppercase tracking-wide">
          Documents
        </span>
        <button
          phx-click="new_document"
          class="w-5 h-5 rounded flex items-center justify-center text-editor-accent-muted hover:text-editor-accent hover:bg-editor-accent-faint/50 transition-colors"
          title="New document"
        >
          +
        </button>
      </div>
      <div class="flex-1 overflow-y-auto py-2">
        <.tree_node
          :for={node <- @tree}
          node={node}
          current_path={@current_path}
        />
      </div>
    </div>
    """
  end

  attr(:node, :map, required: true)
  attr(:current_path, :string, default: nil)

  defp tree_node(%{node: %{type: :directory}} = assigns) do
    ~H"""
    <div class="mb-1">
      <div class="px-3 py-0.5 text-xs font-medium text-editor-accent-muted uppercase tracking-wide">
        {@node.name}
      </div>
      <.tree_node
        :for={child <- @node.children}
        node={child}
        current_path={@current_path}
      />
    </div>
    """
  end

  defp tree_node(%{node: %{type: :file}} = assigns) do
    ~H"""
    <button
      phx-click="open_document"
      phx-value-path={@node.path}
      class={[
        "w-full text-left px-4 py-0.5 text-sm truncate transition-colors",
        if(@node.path == @current_path,
          do: "text-editor-accent bg-editor-accent-faint",
          else: "text-editor-text-muted hover:text-editor-text hover:bg-editor-accent-faint/50"
        )
      ]}
    >
      {@node.name}
    </button>
    """
  end

  @doc """
  Converts a flat list of file paths into a nested tree structure.

  Each node is either:
  - `%{type: :directory, name: String.t(), children: [node]}`
  - `%{type: :file, name: String.t(), path: String.t()}`

  Files in the root directory appear before subdirectories in the returned list.
  """
  def build_tree(paths) do
    grouped = Enum.group_by(paths, &path_prefix/1)
    root_files = Map.get(grouped, :root, [])
    dirs = Map.drop(grouped, [:root])

    root_nodes = Enum.map(root_files, &file_node/1)
    dir_nodes = dirs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&dir_node/1)

    root_nodes ++ dir_nodes
  end

  defp path_prefix(path) do
    case Path.split(path) do
      [_file] -> :root
      [dir | _rest] -> dir
    end
  end

  defp file_node(path) do
    %{type: :file, name: Path.basename(path), path: path}
  end

  defp dir_node({dir, paths}) do
    children = Enum.map(paths, &file_node/1)
    %{type: :directory, name: dir, children: children}
  end
end
