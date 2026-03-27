defmodule SkillKit.Web.EditorLive do
  use Phoenix.LiveView,
    layout: {SkillKit.Web.Layouts, :app}

  alias SkillKit.Web.Components.DocumentTree
  alias SkillKit.Web.Components.EditorSurface
  alias SkillKit.Web.Components.Sidebar
  alias SkillKit.Web.Components.ThemeToggle

  @impl true
  def mount(_params, _session, socket) do
    root = SkillKitWeb.project_root()
    files = list_files(root)
    {current_path, content} = open_first_file(root, files)

    socket =
      socket
      |> assign(:project_root, root)
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
      <div class="relative flex-1 flex">
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
    root = socket.assigns.project_root
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
    root = socket.assigns.project_root
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
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp open_first_file(_root, []), do: {nil, nil}

  defp open_first_file(root, [first | _rest]) do
    content = File.read!(Path.join(root, first))
    {first, content}
  end

  defp toggle_drawer(current, panel) when current == panel, do: nil
  defp toggle_drawer(_current, panel), do: panel
end
