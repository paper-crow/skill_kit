defmodule SkillKit.Web.EditorLive do
  use Phoenix.LiveView,
    layout: {SkillKit.Web.Layouts, :app}

  alias SkillKit.Agent.Definition
  alias SkillKit.Web.Components.ChatDrawer
  alias SkillKit.Web.Components.DocumentTree
  alias SkillKit.Web.Components.EditorSurface
  alias SkillKit.Web.Components.Sidebar
  alias SkillKit.Web.Components.ThemeToggle
  alias SkillKit.Web.ConversationStore
  alias SkillKit.Web.EditorScope

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
      |> assign(:chat_messages, [])
      |> assign(:streaming_text, nil)
      |> assign(:agent_ref, nil)

    socket = maybe_start_agent(socket)

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
        <ChatDrawer.chat_drawer
          messages={@chat_messages}
          streaming_text={@streaming_text}
          open={@active_drawer == :chat}
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
  def handle_event("send_chat_message", %{"message" => message}, socket)
      when message != "" do
    user_msg = %{role: :user, content: message}
    messages = socket.assigns.chat_messages ++ [user_msg]
    socket = assign(socket, :chat_messages, messages)

    case socket.assigns.agent_ref do
      nil ->
        {:noreply, socket}

      agent_ref ->
        SkillKit.send_message(agent_ref, message)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_chat_message", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("text_selected", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%SkillKit.Event.Delta{text: text}, socket) do
    current = socket.assigns.streaming_text || ""
    {:noreply, assign(socket, :streaming_text, current <> text)}
  end

  @impl true
  def handle_info(%SkillKit.Types.AssistantMessage{content: content}, socket) do
    message = %{role: :assistant, content: content}
    messages = socket.assigns.chat_messages ++ [message]

    socket =
      socket
      |> assign(:chat_messages, messages)
      |> assign(:streaming_text, nil)
      |> refresh_files()

    {:noreply, socket}
  end

  @impl true
  def handle_info(%SkillKit.Event.ToolCallStart{}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%SkillKit.Event.ToolCallComplete{}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%SkillKit.Types.ToolResult{}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%SkillKit.Event.Error{reason: reason}, socket) do
    message = %{role: :assistant, content: "Error: #{inspect(reason)}"}
    messages = socket.assigns.chat_messages ++ [message]

    socket =
      socket
      |> assign(:chat_messages, messages)
      |> assign(:streaming_text, nil)

    {:noreply, socket}
  end

  defp maybe_start_agent(socket) do
    if connected?(socket) do
      handle_agent_start(socket)
    else
      socket
    end
  end

  defp handle_agent_start(socket) do
    case start_agent(socket.assigns.docs_root) do
      {:ok, agent_ref} ->
        assign(socket, :agent_ref, agent_ref)

      {:error, reason} ->
        error_msg = %{
          role: :assistant,
          content:
            "Could not start agent: #{inspect(reason)}. Chat is unavailable, but you can still browse documents."
        }

        socket
        |> assign(:chat_messages, [error_msg])
        |> assign(:agent_ref, nil)
    end
  end

  defp start_agent(docs_root) do
    agent_path = Application.app_dir(:skill_kit_web, "priv/agents/assistant.md")
    project_root = SkillKitWeb.project_root()

    conversations_dir = Path.join(project_root, ".skill_kit/conversations")

    scope = %EditorScope{
      project_root: project_root,
      docs_root: docs_root
    }

    case Definition.parse(agent_path) do
      {:ok, definition} ->
        SkillKit.start_agent(definition,
          caller: self(),
          skills: [{SkillKit.Web.DocumentKit, []}],
          scope: scope,
          conversation_store: {ConversationStore, dir: conversations_dir}
        )

      {:error, reason} ->
        {:error, reason}
    end
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

  defp refresh_files(socket) do
    files = list_files(socket.assigns.docs_root)
    assign(socket, :files, files)
  end
end
