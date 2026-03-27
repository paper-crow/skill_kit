defmodule SkillKit.Web.EditorLive do
  use Phoenix.LiveView,
    layout: {SkillKit.Web.Layouts, :app}

  alias SkillKit.Web.Components.DocumentTree
  alias SkillKit.Web.Components.EditorSurface
  alias SkillKit.Web.Components.Sidebar
  alias SkillKit.Web.Components.ThemeToggle

  @impl true
  def mount(_params, _session, socket) do
    docs_root = SkillKitWeb.docs_root()
    File.mkdir_p!(docs_root)
    files = list_files(docs_root)
    {current_path, content} = open_first_file(docs_root, files)

    socket =
      socket
      |> assign(:docs_root, docs_root)
      |> assign(:files, files)
      |> assign(:current_path, current_path)
      |> assign(:content, content)
      |> assign(:active_drawer, nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full w-full">
      <Sidebar.sidebar active={@active_drawer} />
      <div class="flex-1 flex overflow-hidden">
        <DocumentTree.document_tree
          files={@files}
          current_path={@current_path}
          open={@active_drawer == :docs}
        />
        <EditorSurface.editor_surface
          content={@content}
          path={@current_path}
          threads={[]}
        />
      </div>
      <div class="absolute bottom-2 left-2 z-20">
        <ThemeToggle.theme_toggle />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_drawer", %{"panel" => panel}, socket) do
    panel_atom = String.to_existing_atom(panel)
    active = toggle_drawer(socket.assigns.active_drawer, panel_atom)
    {:noreply, assign(socket, :active_drawer, active)}
  end

  @impl true
  def handle_event("open_document", %{"path" => path}, socket) do
    root = socket.assigns.docs_root
    full_path = Path.join(root, path)
    content = File.read!(full_path)

    socket =
      socket
      |> assign(:current_path, path)
      |> assign(:content, content)

    {:noreply, socket}
  end

  @impl true
  def handle_event("editor_change", %{"content" => content}, socket) do
    root = socket.assigns.docs_root
    full_path = Path.join(root, socket.assigns.current_path)
    File.write!(full_path, content)
    {:noreply, assign(socket, :content, content)}
  end

  @impl true
  def handle_event("new_document", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("text_selected", _params, socket) do
    {:noreply, socket}
  end

  defp list_files(root) do
    root
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.map(&file_entry(root, &1))
    |> Enum.sort_by(& &1.path)
  end

  defp file_entry(root, full_path) do
    path = Path.relative_to(full_path, root)
    title = extract_title(full_path, path)
    %{path: path, title: title}
  end

  defp extract_title(full_path, path) do
    case File.open(full_path, [:read], &IO.read(&1, :line)) do
      {:ok, "# " <> heading} -> String.trim(heading)
      _other -> Path.basename(path)
    end
  end

  defp open_first_file(_root, []), do: {nil, nil}

  defp open_first_file(root, [%{path: path} | _rest]) do
    content = File.read!(Path.join(root, path))
    {path, content}
  end

  defp toggle_drawer(current, panel) when current == panel, do: nil
  defp toggle_drawer(_current, panel), do: panel
end
