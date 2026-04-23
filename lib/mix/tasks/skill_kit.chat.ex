defmodule Mix.Tasks.SkillKit.Chat do
  @moduledoc """
  Interactive chat session with a SkillKit agent.

      mix skill_kit.chat            # select agent interactively
      mix skill_kit.chat neve       # start specific agent
      mix skill_kit.chat researcher

  ## Webhook dev server

  Each chat session starts `SkillKit.Webhook` and an HTTP listener on
  `SKILL_KIT_WEBHOOK_PORT` (default 4001). Agents loaded with the
  `SkillKit.Tools.Webhook` kit can register endpoints through the
  `webhook:register` skill:

      you> add a webhook with verifier type "none" that echoes the body
      agent> Webhook registered. URL: http://localhost:4001/<id>
      $ curl -d "hi" http://localhost:4001/<id>
      # agent receives "hi" as a user message and responds in the chat.
  """

  use Mix.Task

  alias SkillKit.Agent
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Error
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.ToolResult

  @shortdoc "Start an interactive agent chat session"

  @default_webhook_port 4001

  @impl true
  def run(args) do
    load_dotenv()
    Mix.Task.run("app.start")

    agents_dir = System.get_env("SKILL_KIT_AGENTS", "examples/agents")
    webhook_port = webhook_port()

    agent_name =
      case args do
        [name | _] -> name
        [] -> select_agent(agents_dir)
      end

    agent_md = Path.join([agents_dir, agent_name, "AGENT.md"])

    unless File.exists?(agent_md) do
      Mix.shell().error("Agent not found: #{agent_name}")
      Mix.shell().error("Available: #{Enum.join(list_agents(agents_dir), ", ")}")
      exit({:shutdown, 1})
    end

    {:ok, content} = File.read(agent_md)
    {:ok, definition} = Agent.parse(content)

    {:ok, webhook_sup} = SkillKit.Webhook.Supervisor.start_link([])
    {:ok, http_sup} = start_webhook_server(webhook_port)
    configure_webhook_base_url(webhook_port)

    {:ok, printer} = Task.start_link(fn -> printer_loop(definition.name) end)

    {:ok, agent} =
      SkillKit.start_agent(definition,
        tools: [{SkillKit.Tools.Shell, []}],
        skills: [{SkillKit.Tools.Webhook, []}],
        caller: printer
      )

    print_banner(definition, webhook_port)

    chat_loop(agent, definition.name)

    SkillKit.stop_agent(agent)
    Process.exit(printer, :shutdown)
    Process.exit(http_sup, :shutdown)
    Process.exit(webhook_sup, :shutdown)
  end

  # Loads KEY=value pairs from a project-root `.env` into the process
  # environment. Lines starting with `#` are ignored. Existing env vars
  # take precedence (so a shell export can override the file).
  defp load_dotenv do
    case File.read(".env") do
      {:ok, content} -> apply_dotenv(content)
      {:error, _} -> :ok
    end
  end

  defp apply_dotenv(content) do
    content
    |> String.split("\n")
    |> Enum.each(&put_env_line/1)
  end

  defp put_env_line(line) do
    trimmed = String.trim(line)
    put_env_kv(trimmed)
  end

  defp put_env_kv(""), do: :ok
  defp put_env_kv("#" <> _), do: :ok

  defp put_env_kv(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> put_env_if_missing(String.trim(key), unquote_value(value))
      _ -> :ok
    end
  end

  defp put_env_if_missing(key, value) do
    case System.get_env(key) do
      nil -> System.put_env(key, value)
      _existing -> :ok
    end
  end

  defp unquote_value(value) do
    trimmed = String.trim(value)
    strip_quotes(trimmed)
  end

  defp strip_quotes(<<?", rest::binary>>), do: String.trim_trailing(rest, ~s("))
  defp strip_quotes(<<?', rest::binary>>), do: String.trim_trailing(rest, "'")
  defp strip_quotes(value), do: value

  defp webhook_port do
    case System.get_env("SKILL_KIT_WEBHOOK_PORT") do
      nil ->
        @default_webhook_port

      raw ->
        {port, ""} = Integer.parse(raw)
        port
    end
  end

  defp start_webhook_server(port) do
    Bandit.start_link(plug: Mix.Tasks.SkillKit.Chat.WebhookHost, port: port, scheme: :http)
  end

  defp configure_webhook_base_url(port) do
    Application.put_env(:skill_kit, :webhook_base_url, "http://localhost:#{port}")
  end

  defp print_banner(definition, webhook_port) do
    IO.puts(
      IO.ANSI.format([
        :bright,
        "\n#{definition.name}",
        :reset,
        :faint,
        " — #{definition.description}"
      ])
    )

    IO.puts(
      IO.ANSI.format([
        :faint,
        "webhooks listening on http://localhost:#{webhook_port}",
        :reset
      ])
    )

    IO.puts(IO.ANSI.format([:faint, "type 'exit' to quit\n"]))
  end

  defp select_agent(agents_dir) do
    case list_agents(agents_dir) do
      [] ->
        Mix.shell().error("No agents found in #{agents_dir}")
        exit({:shutdown, 1})

      [single] ->
        single

      agents ->
        print_agent_menu(agents, agents_dir)
        prompt_agent_choice(agents)
    end
  end

  defp print_agent_menu(agents, agents_dir) do
    IO.puts(IO.ANSI.format([:bright, "\nAvailable agents:\n"]))

    agents
    |> Enum.with_index(1)
    |> Enum.each(fn {name, i} ->
      desc = agent_description(agents_dir, name)

      IO.puts(IO.ANSI.format(["  ", :bright, "#{i}", :reset, ") #{name}", :faint, " — #{desc}"]))
    end)

    IO.puts("")
  end

  defp agent_description(agents_dir, name) do
    agent_md = Path.join([agents_dir, name, "AGENT.md"])
    describe(read_and_parse(agent_md))
  end

  defp read_and_parse(agent_md) do
    with {:ok, content} <- File.read(agent_md) do
      Agent.parse(content)
    end
  end

  defp describe({:ok, definition}), do: definition.description
  defp describe(_), do: ""

  defp prompt_agent_choice(agents) do
    input = String.trim(IO.gets("Select agent: "))

    case Integer.parse(input) do
      {n, ""} when n >= 1 and n <= length(agents) -> Enum.at(agents, n - 1)
      _ -> if input in agents, do: input, else: List.first(agents)
    end
  end

  defp list_agents(agents_dir) do
    case File.ls(agents_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name ->
          File.exists?(Path.join([agents_dir, name, "AGENT.md"]))
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp chat_loop(agent, agent_name) do
    case IO.gets("you> ") do
      :eof ->
        :ok

      input ->
        prompt = String.trim(input)
        handle_prompt(prompt, agent, agent_name)
    end
  end

  defp handle_prompt("exit", _agent, _agent_name), do: IO.puts("Goodbye.")

  defp handle_prompt("", agent, agent_name), do: chat_loop(agent, agent_name)

  defp handle_prompt(prompt, agent, agent_name) do
    :ok = SkillKit.send_message(agent, prompt)
    chat_loop(agent, agent_name)
  end

  # Printer Task — receives all agent events and prints as they arrive,
  # independent of the chat loop's stdin blocking. Matches on the root
  # agent name as a prefix so events from activate_skill child agents
  # (named "<root>/skill:<skill_name>-<n>") are also displayed.
  defp printer_loop(root_name) do
    receive do
      %Delta{agent: agent, text: text} ->
        if agent == root_name, do: IO.write(text)

      %ToolCallComplete{agent: agent, name: name, input: input} ->
        print_tool_call(origin(agent, root_name), name, input)

      %ToolResult{agent: agent} = result ->
        print_tool_result(origin(agent, root_name), result)

      %AssistantMessage{agent: agent} ->
        if agent == root_name, do: IO.puts("\n")

      %Error{agent: agent, reason: reason} ->
        if belongs_to?(agent, root_name) do
          IO.puts("\n[error] #{inspect(reason)}\n")
        end

      _other ->
        :ok
    end

    printer_loop(root_name)
  end

  defp origin(agent_name, root_name) do
    cond do
      agent_name == root_name -> :root
      String.starts_with?(agent_name, root_name <> "/") -> :subloop
      true -> :other
    end
  end

  defp belongs_to?(agent_name, root_name) do
    agent_name == root_name or String.starts_with?(agent_name, root_name <> "/")
  end

  defp print_tool_call(:root, name, input) do
    IO.puts(IO.ANSI.format([:faint, "  ↳ #{name}(#{format_input(name, input)})"]))
  end

  defp print_tool_call(:subloop, name, input) do
    IO.puts(IO.ANSI.format([:cyan, "  ↳ #{name}(#{format_input(name, input)})"]))
  end

  defp print_tool_call(:other, _name, _input), do: :ok

  # Skip printing the final `activate_skill` tool result — the sub-loop
  # already streamed that text via Delta events, so printing it again
  # (truncated) just looks like a duplicate ghost message.
  defp print_tool_result(_origin, %ToolResult{name: "activate_skill", is_error: false}), do: :ok

  defp print_tool_result(:root, %ToolResult{is_error: true, content: content}) do
    IO.puts(IO.ANSI.format([:red, "  ← error: ", :reset, truncate(content)]))
  end

  defp print_tool_result(:root, %ToolResult{content: content}) do
    IO.puts(IO.ANSI.format([:faint, "  ← ", truncate(content)]))
  end

  defp print_tool_result(:subloop, %ToolResult{is_error: true, content: content}) do
    IO.puts(IO.ANSI.format([:red, "  ← error: ", :reset, truncate(content)]))
  end

  defp print_tool_result(:subloop, %ToolResult{content: content}) do
    IO.puts(IO.ANSI.format([:cyan, "  ← ", truncate(content)]))
  end

  defp print_tool_result(:other, _result), do: :ok

  defp truncate(content) when is_binary(content) do
    if String.length(content) > 240, do: String.slice(content, 0, 240) <> "…", else: content
  end

  defp truncate(content), do: inspect(content, limit: 4)

  defp format_input("bash", %{"command" => cmd}), do: cmd
  defp format_input("activate_skill", %{"name" => name}), do: name
  defp format_input(_name, input) when map_size(input) == 0, do: ""
  defp format_input(_name, input), do: inspect(input, limit: 3)
end

defmodule Mix.Tasks.SkillKit.Chat.WebhookHost do
  @moduledoc false
  # Top-level Plug for the chat dev server. Reads the raw body into
  # `conn.assigns.raw_body` (required by HMAC verifiers) and hands the
  # conn to `SkillKit.Webhook.Plug`.

  @behaviour Plug

  alias SkillKit.Webhook.Plug, as: WebhookPlug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    case Plug.Conn.read_body(conn, []) do
      {:ok, body, conn} ->
        conn
        |> Plug.Conn.assign(:raw_body, body)
        |> WebhookPlug.call(WebhookPlug.init([]))

      {:more, _partial, conn} ->
        Plug.Conn.send_resp(conn, 413, "request body too large")

      {:error, _reason} ->
        Plug.Conn.send_resp(conn, 400, "")
    end
  end
end
