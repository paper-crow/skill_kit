defmodule SkillKit.Web.OnboardingLive do
  use Phoenix.LiveView,
    layout: {SkillKit.Web.Layouts, :app}

  alias SkillKit.Agent.Definition
  alias SkillKit.Web.ConversationStore
  alias SkillKit.Web.DocumentKit
  alias SkillKit.Web.EditorScope

  @fixed_questions [
    %{
      question: "What's the one thing it needs to do?",
      subtext: "Don't overthink it — just the core action.",
      placeholder: "manage inventory for our warehouse"
    },
    %{
      question: "Give it a working name",
      subtext: "You can always change this later.",
      placeholder: "e.g. Stockpile"
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    docs_root = SkillKitWeb.docs_root()
    File.mkdir_p!(docs_root)

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class={[
      "flex items-center h-full w-full bg-editor-bg",
      transition_class(@transitioning)
    ]}>
      <div class="pl-16 max-w-lg">
        <div :if={@error} class="font-heading text-2xl text-editor-text leading-snug mb-2">
          {@error}
        </div>
        <div :if={!@error}>
          <h1 class="font-heading text-[28px] text-editor-text leading-snug mb-2">
            <.animated_words
              :if={@animate_question}
              text={@question}
              key={@question_key}
            />
            <span :if={!@animate_question}>{@question}</span>
          </h1>
          <p
            :if={@subtext}
            class={[
              "text-[15px] text-editor-text-faint leading-relaxed mb-9",
              if(@animate_question, do: "animate-onboarding-fade-in opacity-0", else: "")
            ]}
            style={if(@animate_question, do: "animation-delay: #{word_count(@question) * 40 + 100}ms", else: "")}
          >
            {@subtext}
          </p>
          <div
            class={[
              "mt-9",
              if(@animate_question, do: "animate-onboarding-fade-in opacity-0", else: "")
            ]}
            style={if(@animate_question, do: "animation-delay: #{word_count(@question) * 40 + 200}ms", else: "")}
          >
            <form phx-submit="submit_answer" class="relative max-w-md">
              <input
                id={"onboarding-input-#{@question_key}"}
                name="answer"
                type="text"
                placeholder={@placeholder}
                autocomplete="off"
                disabled={@waiting}
                phx-hook="OnboardingInput"
                class="w-full bg-white dark:bg-editor-bg-alt border border-editor-border rounded-xl
                       px-5 py-4 pr-16 text-[15px] text-editor-text placeholder-editor-text-faint
                       focus:outline-none focus:border-editor-accent-muted
                       disabled:opacity-50 transition-colors"
              />
              <button
                type="submit"
                disabled={@waiting}
                class="absolute right-3 top-1/2 -translate-y-1/2
                       w-9 h-9 rounded-full bg-editor-accent text-white
                       flex items-center justify-center
                       hover:opacity-90 disabled:opacity-40 transition-opacity"
              >
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4">
                  <path
                    fill-rule="evenodd"
                    d="M10 17a.75.75 0 01-.75-.75V5.612L5.29 9.77a.75.75 0 01-1.08-1.04l5.25-5.5a.75.75 0 011.08 0l5.25 5.5a.75.75 0 11-1.08 1.04l-3.96-4.158V16.25A.75.75 0 0110 17z"
                    clip-rule="evenodd"
                  />
                </svg>
              </button>
            </form>
          </div>
        </div>
      </div>
      <button
        id="onboarding-theme-toggle"
        phx-hook="Theme"
        class="fixed bottom-6 left-8 text-editor-text-faint hover:text-editor-accent-muted
               text-sm transition-colors"
        title="Toggle theme"
      >
        <span class="dark:hidden">&#9790;</span>
        <span class="hidden dark:inline">&#9728;</span>
      </button>
    </div>
    """
  end

  attr(:text, :string, required: true)
  attr(:key, :integer, required: true)

  defp animated_words(assigns) do
    words = String.split(assigns.text)
    assigns = assign(assigns, :words, words)

    ~H"""
    <span
      :for={{word, idx} <- Enum.with_index(@words)}
      class="inline-block animate-onboarding-word-reveal opacity-0"
      style={"animation-delay: #{idx * 40}ms"}
    >{word}<span :if={idx < length(@words) - 1}>&nbsp;</span></span>
    """
  end

  # -- Mount helpers -----------------------------------------------------------

  defp mount_onboarding(socket, docs_root, nil) do
    conversation_id = generate_conversation_id(docs_root)

    socket =
      socket
      |> assign_onboarding_defaults(docs_root, conversation_id)
      |> assign_fixed_question(0)

    {:ok, socket}
  end

  defp mount_onboarding(socket, docs_root, conversation_id) do
    conversations_dir = SkillKitWeb.conversations_dir()

    case ConversationStore.load(conversation_id, dir: conversations_dir) do
      {:ok, []} ->
        socket =
          socket
          |> assign_onboarding_defaults(docs_root, conversation_id)
          |> assign_fixed_question(0)

        {:ok, socket}

      {:ok, messages} ->
        {pairs, current_question} = replay_conversation(messages)

        socket =
          socket
          |> assign_onboarding_defaults(docs_root, conversation_id)
          |> assign(:pairs, pairs)
          |> assign(:fixed_index, length(@fixed_questions))

        socket =
          if current_question do
            assign_question(socket, current_question)
          else
            assign_fixed_question(socket, min(length(pairs), length(@fixed_questions) - 1))
          end

        {:ok, maybe_start_agent(socket)}

      {:error, _} ->
        socket =
          socket
          |> assign_onboarding_defaults(docs_root, conversation_id)
          |> assign_fixed_question(0)

        {:ok, socket}
    end
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
  end

  defp assign_fixed_question(socket, index) when index < length(@fixed_questions) do
    q = Enum.at(@fixed_questions, index)

    socket
    |> assign(:question, q.question)
    |> assign(:subtext, q.subtext)
    |> assign(:placeholder, q.placeholder)
    |> assign(:fixed_index, index)
  end

  defp assign_fixed_question(socket, _index) do
    assign(socket, :waiting, true)
  end

  defp assign_question(socket, %{question: q, subtext: s}) do
    socket
    |> assign(:question, q)
    |> assign(:subtext, s)
    |> assign(:placeholder, "")
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

    if next_index < length(@fixed_questions) do
      socket = assign_fixed_question(socket, next_index)
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:waiting, true)
        |> maybe_start_agent()
        |> send_pairs_to_agent()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("submit_answer", _params, socket) do
    {:noreply, socket}
  end

  # -- Agent messages ----------------------------------------------------------

  @impl true
  def handle_info(%SkillKit.Event.Delta{}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %SkillKit.Types.AssistantMessage{content: content, tool_calls: tool_calls},
        socket
      ) do
    if has_doc_create?(tool_calls) do
      Process.send_after(self(), :complete_transition, 600)
      {:noreply, assign(socket, :transitioning, :out)}
    else
      parsed = parse_question(content)
      {:noreply, assign_question(socket, parsed)}
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
    conversations_dir = SkillKitWeb.conversations_dir()
    ConversationStore.delete(socket.assigns.conversation_id, dir: conversations_dir)

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
    agent_path = Path.join(:code.priv_dir(:skill_kit_web), "agents/onboarding.md")
    conversations_dir = SkillKitWeb.conversations_dir()

    scope = %EditorScope{
      project_root: SkillKitWeb.project_root(),
      docs_root: socket.assigns.docs_root
    }

    case Definition.parse(agent_path) do
      {:ok, definition} ->
        case SkillKit.start_agent(definition,
               caller: self(),
               skills: [{DocumentKit, []}],
               scope: scope,
               conversation_store: {ConversationStore, dir: conversations_dir},
               conversation_id: socket.assigns.conversation_id
             ) do
          {:ok, agent_ref} ->
            assign(socket, :agent_ref, agent_ref)

          {:error, reason} ->
            assign(
              socket,
              :error,
              "Could not start assistant: #{inspect(reason)}. Try refreshing."
            )
        end

      {:error, reason} ->
        assign(socket, :error, "Could not load agent: #{inspect(reason)}. Try refreshing.")
    end
  end

  defp send_pairs_to_agent(%{assigns: %{agent_ref: nil}} = socket), do: socket

  defp send_pairs_to_agent(socket) do
    message = format_pairs_message(socket.assigns.pairs)
    SkillKit.send_message(socket.assigns.agent_ref, message)
    socket
  end

  defp format_pairs_message(pairs) do
    answers =
      Enum.map_join(pairs, "\n", fn %{question: q, answer: a} ->
        "Q: #{q}\nA: #{a}"
      end)

    "[Onboarding answers]\n#{answers}"
  end

  # -- Parsing -----------------------------------------------------------------

  defp parse_question(nil), do: %{question: "Let me think...", subtext: nil}

  defp parse_question(content) do
    case Regex.run(~r/QUESTION:\s*(.+?)(?:\nSUBTEXT:\s*(.+))?$/s, content) do
      [_, question, subtext] ->
        %{question: String.trim(question), subtext: String.trim(subtext)}

      [_, question] ->
        %{question: String.trim(question), subtext: nil}

      nil ->
        %{question: String.trim(content), subtext: nil}
    end
  end

  defp has_doc_create?(tool_calls) do
    Enum.any?(tool_calls, fn tc -> tc.name == "docs" and tc.input["path"] != nil end)
  end

  # -- Conversation replay -----------------------------------------------------

  defp replay_conversation(messages) do
    {pairs, last_question} =
      Enum.reduce(messages, {[], nil}, fn msg, {pairs_acc, last_q} ->
        case msg do
          %SkillKit.Types.AssistantMessage{content: content} when not is_nil(content) ->
            parsed = parse_question(content)
            {pairs_acc, parsed}

          %SkillKit.Types.UserMessage{content: content} when not is_nil(content) ->
            case last_q do
              nil ->
                {pairs_acc, nil}

              %{question: q} ->
                pair = %{question: q, answer: content}
                {pairs_acc ++ [pair], nil}
            end

          _ ->
            {pairs_acc, last_q}
        end
      end)

    {pairs, last_question}
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

  defp transition_class(:out), do: "animate-onboarding-page-exit"
  defp transition_class(_), do: ""

  defp word_count(text), do: text |> String.split() |> length()
end
