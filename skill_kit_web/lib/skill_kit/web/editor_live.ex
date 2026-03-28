defmodule SkillKit.Web.EditorLive do
  use Phoenix.LiveView,
    layout: {SkillKit.Web.Layouts, :app}

  alias SkillKit.Agent.Definition
  alias SkillKit.Web.Components.ChatDrawer
  alias SkillKit.Web.Components.DebugPanel
  alias SkillKit.Web.Components.DocumentTree
  alias SkillKit.Web.Components.EditorSurface
  alias SkillKit.Web.Components.Sidebar
  alias SkillKit.Web.Components.ThemeToggle
  alias SkillKit.Web.ConversationStore
  alias SkillKit.Web.EditorScope

  @max_debug_events 200

  @telemetry_events [
    [:skill_kit, :tool_use, :start],
    [:skill_kit, :tool_use, :stop],
    [:skill_kit, :tool_use, :exception],
    [:skill_kit, :llm_request, :start],
    [:skill_kit, :llm_request, :stop],
    [:skill_kit, :llm_request, :exception],
    [:skill_kit, :agent, :start],
    [:skill_kit, :agent, :stop],
    [:skill_kit, :agent, :exception],
    [:skill_kit, :turn, :start],
    [:skill_kit, :turn, :stop],
    [:skill_kit, :turn, :exception],
    [:skill_kit, :skill_activation, :start],
    [:skill_kit, :skill_activation, :stop],
    [:skill_kit, :skill_activation, :exception],
    [:skill_kit, :subagent, :start],
    [:skill_kit, :subagent, :stop],
    [:skill_kit, :subagent, :exception],
    [:skill_kit, :conversation_save, :start],
    [:skill_kit, :conversation_save, :stop],
    [:skill_kit, :conversation_save, :exception],
    [:skill_kit, :conversation_load, :start],
    [:skill_kit, :conversation_load, :stop],
    [:skill_kit, :conversation_load, :exception],
    [:skill_kit, :llm, :rate_limited],
    [:skill_kit, :llm, :stream, :start],
    [:skill_kit, :llm, :stream, :stop],
    [:skill_kit, :llm, :stream, :exception],
    [:skill_kit, :llm, :stream, :error],
    [:skill_kit, :agent, :orphaned_result]
  ]

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
      |> assign(:events, [])
      |> assign(:event_count, 0)
      |> assign(:debug_paused, false)
      |> assign(:mermaid_retries, %{})

    socket = maybe_start_agent(socket)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative flex h-full w-full">
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
          open={true}
        />
      </div>
      <DebugPanel.debug_panel
        events={@events}
        event_count={@event_count}
        paused={@debug_paused}
        open={@active_drawer == :build}
      />
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
        SkillKit.send_message(agent_ref, format_message(message, socket.assigns.current_path))
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

  @max_mermaid_retries 2

  @impl true
  def handle_event("mermaid_error", params, socket) do
    retries = Map.get(socket.assigns, :mermaid_retries, %{})
    path = params["path"]
    count = Map.get(retries, path, 0)

    if count >= @max_mermaid_retries or is_nil(socket.assigns.agent_ref) do
      msg = %{
        role: :assistant,
        content:
          "Mermaid diagram in #{path} still has errors after #{count} attempts. Please fix manually."
      }

      {:noreply, assign(socket, :chat_messages, socket.assigns.chat_messages ++ [msg])}
    else
      error_message = build_mermaid_error_message(params)

      system_msg = %{
        role: :assistant,
        content: "Mermaid diagram has a syntax error. Attempting to fix..."
      }

      messages = socket.assigns.chat_messages ++ [system_msg]

      SkillKit.send_message(socket.assigns.agent_ref, error_message)

      socket =
        socket
        |> assign(:chat_messages, messages)
        |> assign(:mermaid_retries, Map.put(retries, path, count + 1))

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("chat_keydown", _params, socket) do
    # Enter key submits via the form's phx-submit; this is a no-op handler
    # to prevent LiveView from complaining about unhandled events
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_debug_pause", _params, socket) do
    {:noreply, assign(socket, :debug_paused, !socket.assigns.debug_paused)}
  end

  @impl true
  def handle_event("clear_debug_events", _params, socket) do
    socket =
      socket
      |> assign(:events, [])
      |> assign(:event_count, 0)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:telemetry_event, event_name, measurements, metadata}, socket) do
    if socket.assigns.debug_paused do
      {:noreply, socket}
    else
      event = build_event(event_name, measurements, metadata)
      events = Enum.take([event | socket.assigns.events], @max_debug_events)
      count = socket.assigns.event_count + 1

      socket =
        socket
        |> assign(:events, events)
        |> assign(:event_count, count)

      {:noreply, socket}
    end
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
      |> reload_current_document()

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

  @impl true
  def handle_info(_unknown, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    handler_id = telemetry_handler_id()
    :telemetry.detach(handler_id)
  rescue
    _ -> :ok
  end

  defp maybe_start_agent(socket) do
    if connected?(socket) do
      attach_telemetry_handlers()
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

  # -- Telemetry ---------------------------------------------------------------

  @doc false
  def handle_telemetry_event(event_name, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp attach_telemetry_handlers do
    :telemetry.attach_many(
      telemetry_handler_id(),
      @telemetry_events,
      &__MODULE__.handle_telemetry_event/4,
      self()
    )
  end

  defp telemetry_handler_id do
    "editor-live-telemetry-#{inspect(self())}"
  end

  defp build_event(event_name, measurements, metadata) do
    %{
      timestamp: format_time(),
      label: format_label(event_name),
      category: categorize(event_name),
      duration: format_duration(measurements),
      detail: format_detail(event_name, measurements, metadata)
    }
  end

  defp format_time do
    now = DateTime.utc_now()
    {microseconds, _precision} = now.microsecond
    ms = div(microseconds, 1000)

    [now.hour, now.minute, now.second]
    |> Enum.map_join(":", &pad_two/1)
    |> Kernel.<>(".#{pad_three(ms)}")
  end

  defp pad_two(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
  defp pad_three(n), do: String.pad_leading(Integer.to_string(n), 3, "0")

  defp format_label(event_name) do
    event_name
    |> Enum.drop(1)
    |> Enum.map_join(":", &upcase_atom/1)
  end

  defp upcase_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.upcase()
  end

  defp categorize(event_name) do
    case Enum.at(event_name, 1) do
      :tool_use -> :tool
      :llm_request -> :llm
      :llm -> :llm
      :agent -> :agent
      :turn -> :turn
      :skill_activation -> :skill
      :subagent -> :agent
      :conversation_save -> :storage
      :conversation_load -> :storage
      _ -> :default
    end
  end

  defp format_duration(%{duration: duration}) when is_integer(duration) do
    ms = System.convert_time_unit(duration, :native, :millisecond)
    "#{ms}ms"
  end

  defp format_duration(_), do: nil

  defp format_detail(event_name, measurements, metadata) do
    parts = event_specific_detail(event_name, measurements, metadata)
    extra = generic_metadata_detail(metadata)
    Enum.join(parts ++ extra, "  ")
  end

  defp event_specific_detail([:skill_kit, :tool_use | _], _m, meta) do
    tool_name = Map.get(meta, :tool_name) || Map.get(meta, :tool)
    build_kv_list([{"tool", tool_name}])
  end

  defp event_specific_detail([:skill_kit, :llm_request | _], measurements, meta) do
    model = Map.get(meta, :model)
    input = Map.get(measurements, :input_tokens) || Map.get(meta, :input_tokens)
    output = Map.get(measurements, :output_tokens) || Map.get(meta, :output_tokens)
    build_kv_list([{"model", model}, {"tokens_in", input}, {"tokens_out", output}])
  end

  defp event_specific_detail([:skill_kit, :llm | _], _m, meta) do
    model = Map.get(meta, :model)
    error = Map.get(meta, :error)
    build_kv_list([{"model", model}, {"error", error}])
  end

  defp event_specific_detail([:skill_kit, :agent | _], _m, meta) do
    agent = Map.get(meta, :agent_name) || Map.get(meta, :name)
    build_kv_list([{"agent", agent}])
  end

  defp event_specific_detail([:skill_kit, :skill_activation | _], _m, meta) do
    skill = Map.get(meta, :skill_name) || Map.get(meta, :skill)
    build_kv_list([{"skill", skill}])
  end

  defp event_specific_detail([:skill_kit, :subagent | _], _m, meta) do
    name = Map.get(meta, :name) || Map.get(meta, :agent_name)
    build_kv_list([{"subagent", name}])
  end

  defp event_specific_detail([:skill_kit, :turn | _], _m, meta) do
    status = Map.get(meta, :status)
    build_kv_list([{"status", status}])
  end

  defp event_specific_detail(_, _m, _meta), do: []

  defp generic_metadata_detail(metadata) do
    metadata
    |> Map.drop([
      :tool_name,
      :tool,
      :model,
      :agent_name,
      :name,
      :skill_name,
      :skill,
      :status,
      :input_tokens,
      :output_tokens,
      :error,
      :kind,
      :reason,
      :stacktrace
    ])
    |> Enum.take(3)
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v, limit: 50, printable_limit: 100)}" end)
  end

  defp build_kv_list(pairs) do
    pairs
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> "#{k}=#{format_value(v)}" end)
  end

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_atom(v), do: Atom.to_string(v)
  defp format_value(v), do: inspect(v, limit: 50, printable_limit: 100)

  # -- File helpers ------------------------------------------------------------

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

  defp format_message(message, nil), do: message
  defp format_message(message, path), do: "[Viewing: #{path}]\n#{message}"

  defp build_mermaid_error_message(%{"error" => error, "source" => source, "path" => path}) do
    """
    A mermaid diagram in #{path} has a syntax error. Please fix it using docs:update.

    Error: #{error}

    The broken mermaid source:
    ```
    #{source}
    ```

    Read the document with docs:read, fix the mermaid block, and update it with docs:update.
    """
  end

  defp reload_current_document(%{assigns: %{current_path: nil}} = socket), do: socket

  defp reload_current_document(socket) do
    full_path = Path.join(socket.assigns.docs_root, socket.assigns.current_path)

    case File.read(full_path) do
      {:ok, content} -> assign(socket, :content, content)
      {:error, _} -> socket
    end
  end

  defp refresh_files(socket) do
    files = list_files(socket.assigns.docs_root)
    assign(socket, :files, files)
  end
end
