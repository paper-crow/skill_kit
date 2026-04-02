defmodule SkillKit.Web.EditorLive do
  use Phoenix.LiveView,
    layout: {SkillKit.Web.Layouts, :app}

  alias SkillKit.Agent.Definition
  alias SkillKit.Web.Components.ChatDrawer
  alias SkillKit.Web.Components.DebugPanel
  alias SkillKit.Web.Components.DocumentTree
  alias SkillKit.Web.Components.EditorSurface
  alias SkillKit.Web.Components.InlineThread

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
  def mount(params, _session, socket) do
    docs_root = SkillKitWeb.docs_root()
    File.mkdir_p!(docs_root)
    files = list_files(docs_root)
    requested_path = path_from_params(params)
    {current_path, content} = open_document(docs_root, files, requested_path)

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
      |> assign(:selection, nil)
      |> assign(:inline_thread, nil)
      |> assign(:suspended_thread, nil)
      |> assign(:pending_diff, nil)

    socket = maybe_start_agent(socket)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested_path = path_from_params(params)

    if requested_path && requested_path != socket.assigns.current_path do
      root = socket.assigns.docs_root
      {current_path, content} = open_document(root, socket.assigns.files, requested_path)

      socket =
        socket
        |> assign(:current_path, current_path)
        |> assign(:content, content)
        |> push_event("scroll_to_top", %{})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative flex h-full w-full">
      <DocumentTree.document_tree
        files={@files}
        current_path={@current_path}
        open={true}
      />
      <div class="flex-1 flex overflow-hidden">
        <EditorSurface.editor_surface
          content={@content}
          path={@current_path}
          threads={[]}
        />
        <ChatDrawer.chat_drawer
          messages={@chat_messages}
          streaming_text={@streaming_text}
          pending_diff={@pending_diff}
          open={true}
        />
      </div>
      <InlineThread.inline_thread thread={@inline_thread} />
      <DebugPanel.debug_panel
        events={@events}
        event_count={@event_count}
        paused={@debug_paused}
        open={@active_drawer == :build}
      />
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
    url_path = String.trim_trailing(path, ".md")
    {:noreply, push_patch(socket, to: "/#{url_path}")}
  end

  @impl true
  def handle_event("editor_change", %{"content" => content}, socket) do
    root = socket.assigns.docs_root
    full_path = Path.join(root, socket.assigns.current_path)

    case File.write(full_path, content) do
      :ok ->
        {:noreply, assign(socket, :content, content)}

      {:error, reason} ->
        error_msg = %{role: :assistant, content: "Save failed: #{inspect(reason)}"}
        {:noreply, assign(socket, :chat_messages, socket.assigns.chat_messages ++ [error_msg])}
    end
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
  def handle_event("text_selected", %{"text" => text, "top" => top, "right" => right}, socket) do
    selection = %{text: text, top: top, right: right}
    thread = restore_or_create_thread(selection, socket.assigns.suspended_thread)

    socket =
      socket
      |> assign(:selection, nil)
      |> assign(:inline_thread, thread)
      |> assign(:suspended_thread, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("text_selected", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    # Only clear selection state, not the thread (thread is closed via dismiss)
    {:noreply, assign(socket, :selection, nil)}
  end

  @impl true
  def handle_event("dismiss_inline_thread", _params, socket) do
    thread = socket.assigns.inline_thread
    suspended = suspend_thread(thread)

    socket =
      socket
      |> assign(:inline_thread, nil)
      |> assign(:suspended_thread, suspended)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_thread_draft", %{"message" => draft}, socket) do
    thread = socket.assigns.inline_thread

    if thread do
      {:noreply, assign(socket, :inline_thread, Map.put(thread, :draft, draft))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_inline_thread", _params, socket) do
    thread = build_inline_thread(socket.assigns.selection)

    socket =
      socket
      |> assign(:inline_thread, thread)
      |> assign(:selection, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_thread_message", %{"message" => message}, socket)
      when message != "" do
    thread = socket.assigns.inline_thread
    user_msg = %{role: :user, content: message}
    updated_thread = %{thread | messages: thread.messages ++ [user_msg]}

    case socket.assigns.agent_ref do
      nil ->
        {:noreply, assign(socket, :inline_thread, updated_thread)}

      agent_ref ->
        context_message = build_thread_message(message, thread, socket.assigns.current_path)
        SkillKit.send_message(agent_ref, context_message)
        {:noreply, assign(socket, :inline_thread, updated_thread)}
    end
  end

  @impl true
  def handle_event("send_thread_message", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("close_inline_thread", _params, socket) do
    {:noreply, assign(socket, inline_thread: nil, suspended_thread: nil)}
  end

  @impl true
  def handle_event("accept_diff", _params, socket) do
    socket =
      socket
      |> assign(:pending_diff, nil)
      |> reload_current_document()

    {:noreply, socket}
  end

  @impl true
  def handle_event("reject_diff", _params, socket) do
    diff = socket.assigns.pending_diff
    full_path = Path.join(socket.assigns.docs_root, diff.path)

    case File.write(full_path, diff.old_content) do
      :ok ->
        socket =
          socket
          |> assign(:pending_diff, nil)
          |> assign(:content, diff.old_content)

        {:noreply, socket}

      {:error, reason} ->
        error_msg = %{role: :assistant, content: "Could not revert file: #{inspect(reason)}"}
        {:noreply, assign(socket, :chat_messages, socket.assigns.chat_messages ++ [error_msg])}
    end
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
    if socket.assigns.inline_thread do
      thread = socket.assigns.inline_thread
      current = thread.streaming_text || ""
      updated = %{thread | streaming_text: current <> text}
      {:noreply, assign(socket, :inline_thread, updated)}
    else
      current = socket.assigns.streaming_text || ""
      {:noreply, assign(socket, :streaming_text, current <> text)}
    end
  end

  @impl true
  def handle_info(%SkillKit.Types.AssistantMessage{content: content}, socket) do
    if socket.assigns.inline_thread do
      socket = route_assistant_to_thread(socket, content)
      {:noreply, socket}
    else
      socket = route_assistant_to_chat(socket, content)
      {:noreply, socket}
    end
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
    agent_path = SkillKitWeb.agent_path()
    project_root = SkillKitWeb.project_root()
    conversations_dir = SkillKitWeb.conversations_dir()

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
    microseconds = System.convert_time_unit(duration, :native, :microsecond)
    humanize_duration(microseconds)
  end

  defp format_duration(_), do: nil

  defp humanize_duration(us) when us < 1_000, do: "#{us}us"
  defp humanize_duration(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp humanize_duration(us) when us < 60_000_000, do: "#{Float.round(us / 1_000_000, 2)}s"
  defp humanize_duration(us), do: "#{Float.round(us / 60_000_000, 1)}min"

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
    {title, headings} = extract_headings(full_path, path)
    %{path: path, title: title, headings: headings}
  end

  defp extract_headings(full_path, path) do
    case File.read(full_path) do
      {:ok, content} -> parse_headings(content, path)
      {:error, _} -> {Path.basename(path), []}
    end
  end

  defp parse_headings(content, path) do
    lines = String.split(content, "\n")
    title = find_title(lines, path)

    headings =
      lines
      |> Enum.filter(&String.starts_with?(&1, "## "))
      |> Enum.map(fn "## " <> text -> String.trim(text) end)

    {title, headings}
  end

  defp find_title(lines, path) do
    case Enum.find(lines, &String.starts_with?(&1, "# ")) do
      "# " <> heading -> String.trim(heading)
      nil -> Path.basename(path)
    end
  end

  defp path_from_params(%{"path" => path_parts}) when is_list(path_parts) do
    joined = Enum.join(path_parts, "/")

    if String.ends_with?(joined, ".md") do
      joined
    else
      joined <> ".md"
    end
  end

  defp path_from_params(_), do: nil

  defp open_document(_root, [], _requested), do: {nil, nil}

  defp open_document(root, files, nil) do
    open_file(root, hd(files).path)
  end

  defp open_document(root, files, requested) do
    if Enum.any?(files, &(&1.path == requested)) do
      open_file(root, requested)
    else
      open_file(root, hd(files).path)
    end
  end

  defp open_file(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, content} -> {path, content}
      {:error, _} -> {path, ""}
    end
  end

  defp toggle_drawer(current, panel) when current == panel, do: nil
  defp toggle_drawer(_current, panel), do: panel

  defp format_message(message, nil), do: message
  defp format_message(message, path), do: "[Viewing: #{path}]\n#{message}"

  defp build_inline_thread(selection) do
    %{
      selection_text: selection.text,
      messages: [],
      streaming_text: nil,
      draft: nil,
      top: selection.top,
      right: selection.right
    }
  end

  defp restore_or_create_thread(selection, nil), do: build_inline_thread(selection)

  defp restore_or_create_thread(selection, suspended) do
    if suspended.selection_text == selection.text do
      %{suspended | top: selection.top, right: selection.right}
    else
      build_inline_thread(selection)
    end
  end

  defp suspend_thread(nil), do: nil

  defp suspend_thread(thread) do
    has_content = thread.draft not in [nil, ""] or thread.messages != []

    if has_content do
      thread
    else
      nil
    end
  end

  defp build_thread_message(message, thread, path) do
    "[Viewing: #{path}]\n[Selected text: \"#{thread.selection_text}\"]\n\n#{message}"
  end

  defp route_assistant_to_thread(socket, content) do
    thread = socket.assigns.inline_thread
    msg = %{role: :assistant, content: content}
    updated = %{thread | messages: thread.messages ++ [msg], streaming_text: nil}

    socket
    |> assign(:inline_thread, updated)
    |> maybe_detect_diff()
    |> refresh_files()
    |> reload_current_document()
  end

  defp route_assistant_to_chat(socket, content) do
    message = %{role: :assistant, content: content}
    messages = socket.assigns.chat_messages ++ [message]

    socket
    |> assign(:chat_messages, messages)
    |> assign(:streaming_text, nil)
    |> maybe_detect_diff()
    |> refresh_files()
    |> reload_current_document()
  end

  defp maybe_detect_diff(%{assigns: %{current_path: nil}} = socket), do: socket

  defp maybe_detect_diff(socket) do
    path = socket.assigns.current_path
    old_content = socket.assigns.content
    full_path = Path.join(socket.assigns.docs_root, path)

    case File.read(full_path) do
      {:ok, new_content} when new_content != old_content ->
        diff = %{path: path, old_content: old_content, new_content: new_content}
        assign(socket, :pending_diff, diff)

      _ ->
        socket
    end
  end

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
