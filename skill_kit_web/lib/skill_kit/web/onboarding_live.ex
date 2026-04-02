defmodule SkillKit.Web.OnboardingLive do
  use Phoenix.LiveView,
    layout: {SkillKit.Web.Layouts, :app}

  alias SkillKit.Web.Agents
  alias SkillKit.Web.Onboarding

  import SkillKit.Web.Components.Onboarding,
    only: [
      error_state: 1,
      ready_state: 1,
      waiting_state: 1,
      question_state: 1
    ]

  @impl true
  def mount(params, _session, socket) do
    docs_root = SkillKitWeb.docs_root()

    if has_documents?(docs_root) do
      first_doc = first_document_path(docs_root)
      {:ok, push_navigate(socket, to: "/#{first_doc}")}
    else
      conversation_id = conversation_id_from_params(params)
      mount_onboarding(socket, docs_root, conversation_id)
    end
  end

  @impl true
  def handle_params(%{"conversation_id" => _id}, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if socket.assigns[:conversation_id] do
      {:noreply,
       push_patch(socket, to: "/setup/#{socket.assigns.conversation_id}", replace: true)}
    else
      {:noreply, socket}
    end
  end

  # -- Mount helpers -----------------------------------------------------------

  defp mount_onboarding(socket, docs_root, nil) do
    conversation_id = generate_conversation_id(docs_root)

    socket =
      socket
      |> assign_onboarding_defaults(docs_root, conversation_id)
      |> schedule_first_question()

    {:ok, socket}
  end

  defp mount_onboarding(socket, docs_root, conversation_id) do
    socket =
      socket
      |> assign_onboarding_defaults(docs_root, conversation_id)
      |> schedule_first_question()

    {:ok, socket}
  end

  defp assign_onboarding_defaults(socket, docs_root, conversation_id) do
    socket
    |> assign(:docs_root, docs_root)
    |> assign(:conversation_id, conversation_id)
    |> assign(:pairs, [])
    |> assign(:fixed_index, 0)
    |> assign(:agent_ref, nil)
    |> assign(:waiting, false)
    |> assign(:transitioning, :none)
    |> assign(:animate_question, true)
    |> assign(:question_key, 0)
    |> assign(:error, nil)
    |> assign(:waiting_text, "Thinking...")
    |> assign(:ready, false)
    |> assign(:summary, nil)
  end

  defp assign_fixed_question(socket, index) do
    case Onboarding.fixed_question(index) do
      nil ->
        assign(socket, :waiting, true)

      q ->
        socket
        |> assign(:question, q.question)
        |> assign(:subtext, q.subtext)
        |> assign(:placeholder, q.placeholder)
        |> assign(:fixed_index, index)
    end
  end

  defp assign_question(socket, question) do
    socket
    |> assign(:question, question.question)
    |> assign(:subtext, question[:subtext])
    |> assign(:placeholder, question[:placeholder] || "")
    |> assign(:animate_question, true)
    |> assign(:question_key, socket.assigns.question_key + 1)
    |> assign(:waiting, false)
  end

  # -- Events ------------------------------------------------------------------

  @impl true
  def handle_event("submit_answer", %{"answer" => answer}, socket)
      when answer != "" do
    pair = %{question: socket.assigns.question, answer: answer}
    pairs = socket.assigns.pairs ++ [pair]
    next_index = socket.assigns.fixed_index + 1

    socket =
      socket
      |> assign(:pairs, pairs)
      |> assign(:animate_question, true)
      |> assign(:question_key, socket.assigns.question_key + 1)
      |> assign(:waiting, true)
      |> assign(:waiting_text, "Thinking...")

    cond do
      next_index < Onboarding.fixed_question_count() ->
        Process.send_after(self(), {:show_fixed_question, next_index}, fake_thinking_delay())
        {:noreply, socket}

      is_nil(socket.assigns.agent_ref) ->
        # Last fixed question — start agent and send all answers
        socket =
          socket
          |> maybe_start_agent()
          |> send_pairs_to_agent()

        {:noreply, socket}

      true ->
        # Agent phase — send answer directly to agent
        SkillKit.send_message(socket.assigns.agent_ref, answer)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("submit_answer", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("get_started", _params, socket) do
    Process.send_after(self(), :complete_transition, 600)
    {:noreply, assign(socket, :transitioning, :out)}
  end

  # -- Agent messages ----------------------------------------------------------

  @impl true
  def handle_info({:show_fixed_question, index}, socket) do
    socket =
      socket
      |> assign_fixed_question(index)
      |> assign(:waiting, false)
      |> assign(:animate_question, true)
      |> assign(:question_key, socket.assigns.question_key + 1)

    {:noreply, socket}
  end

  @impl true
  def handle_info(%SkillKit.Event.Delta{}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %SkillKit.Types.AssistantMessage{content: content, tool_calls: tool_calls},
        socket
      ) do
    cond do
      socket.assigns.transitioning != :none ->
        {:noreply, socket}

      has_doc_create?(tool_calls) ->
        {:noreply, assign(socket, waiting: true, waiting_text: "Creating your project brief...")}

      has_documents?(socket.assigns.docs_root) ->
        {:noreply, assign(socket, ready: true, summary: content)}

      is_binary(content) and content != "" ->
        parsed = Onboarding.parse_response(content)
        {:noreply, assign_question(socket, parsed)}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%SkillKit.Event.ToolCallStart{}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(%SkillKit.Event.ToolCallComplete{}, socket) do
    if has_documents?(socket.assigns.docs_root) do
      Process.send_after(self(), :complete_transition, 600)
      {:noreply, assign(socket, :transitioning, :out)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%SkillKit.Types.ToolResult{}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(%SkillKit.Event.Error{reason: reason}, socket) do
    {:noreply,
     assign(socket, :error, "Something went wrong: #{inspect(reason)}. Try refreshing.")}
  end

  @impl true
  def handle_info(:complete_transition, socket) do
    doc_path = first_document_path(socket.assigns.docs_root)
    {:noreply, push_navigate(socket, to: "/#{doc_path}")}
  end

  @impl true
  def handle_info(_unknown, socket), do: {:noreply, socket}

  # -- Agent -------------------------------------------------------------------

  defp maybe_start_agent(%{assigns: %{agent_ref: ref}} = socket) when not is_nil(ref) do
    socket
  end

  defp maybe_start_agent(socket) do
    if connected?(socket) do
      handle_agent_start(socket)
    else
      socket
    end
  end

  defp handle_agent_start(socket) do
    case Agents.start_onboarding(self(), socket.assigns.conversation_id) do
      {:ok, agent_ref} ->
        assign(socket, :agent_ref, agent_ref)

      {:error, reason} ->
        assign(socket, :error, "Could not start assistant: #{inspect(reason)}. Try refreshing.")
    end
  end

  defp send_pairs_to_agent(%{assigns: %{agent_ref: nil}} = socket), do: socket

  defp send_pairs_to_agent(socket) do
    message = Onboarding.format_pairs_message(socket.assigns.pairs)
    SkillKit.send_message(socket.assigns.agent_ref, message)
    socket
  end

  defp has_doc_create?(tool_calls) do
    Enum.any?(tool_calls, fn tc -> tc.name == "docs" and tc.input["path"] != nil end)
  end

  # -- Helpers -----------------------------------------------------------------

  defp has_documents?(docs_root) do
    docs_root
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.any?()
  end

  defp first_document_path(docs_root) do
    docs_root
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> List.first()
    |> Path.relative_to(docs_root)
    |> String.trim_trailing(".md")
  end

  defp generate_conversation_id(docs_root) do
    hash =
      docs_root
      |> :erlang.phash2()
      |> Integer.to_string(16)
      |> String.downcase()

    "onboarding-#{hash}"
  end

  defp conversation_id_from_params(%{"conversation_id" => id}), do: id
  defp conversation_id_from_params(_), do: nil

  defp schedule_first_question(socket) do
    socket
    |> assign_fixed_question(0)
    |> assign(:waiting, false)
    |> assign(:animate_question, true)
  end

  defp fake_thinking_delay, do: Enum.random(800..1500)
end
