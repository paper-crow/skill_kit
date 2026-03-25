defmodule PersonaChat.CLI do
  @moduledoc """
  CLI harness for the PersonaChat example app.

  Usage:
    mix persona_chat --user alice                        # list and select persona
    mix persona_chat --user alice --persona pirate_pete  # direct to chat
    mix persona_chat --user alice --manage               # lobby for create/delete
  """

  alias SkillKit.Agent.Definition
  alias SkillKit.Event.Delta
  alias SkillKit.Types.AssistantMessage

  @data_dir "data"
  @personas_dir "personas"
  @config_file "data/config.json"

  def main(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [user: :string, persona: :string, manage: :boolean]
      )

    username = opts[:user] || raise "Missing required --user flag"
    owner = owner?(username)

    cond do
      opts[:manage] ->
        run_lobby(username, owner)

      opts[:persona] ->
        run_persona_chat(username, opts[:persona], owner)

      true ->
        select_and_chat(username, owner)
    end
  end

  defp run_lobby(username, owner) do
    scope = PersonaChat.Scope.build(username, nil, owner: owner)

    {:ok, agent} =
      SkillKit.start_agent(
        sources: [{SkillKit.Backend.Filesystem, dir: ".skills"}],
        scope: scope
      )

    IO.puts("=== Persona Chat Lobby ===")
    IO.puts("Logged in as: #{username}#{if owner, do: " (owner)", else: ""}")
    IO.puts("Type /quit to exit.\n")

    chat_loop(agent)
    SkillKit.stop_agent(agent)
  end

  defp run_persona_chat(username, persona_name, owner) do
    persona_dir = "#{@personas_dir}/#{persona_name}"

    unless File.dir?(persona_dir) do
      IO.puts("Persona '#{persona_name}' not found. Available personas:")
      list_available_personas()
      System.halt(1)
    end

    scope = PersonaChat.Scope.build(username, persona_name, owner: owner)

    {:ok, agent} =
      SkillKit.start_agent(
        sources: [
          {SkillKit.Backend.Filesystem, dir: "#{@personas_dir}/#{persona_name}"},
          {SkillKit.Backend.Filesystem, dir: ".skills/memory_kit"}
        ],
        name: "#{persona_name}:#{username}",
        scope: scope,
        conversation_store:
          {SkillKit.Conversation.Store.Filesystem, path: "#{@data_dir}/conversations"}
      )

    IO.puts("=== Chatting with #{persona_name} ===")
    IO.puts("Logged in as: #{username}")
    IO.puts("Type /quit to exit.\n")

    chat_loop(agent)
    SkillKit.stop_agent(agent)
  end

  defp chat_loop(agent) do
    case IO.gets("> ") do
      :eof ->
        :ok

      input ->
        trimmed = String.trim(input)
        handle_input(agent, trimmed)
    end
  end

  defp handle_input(_agent, "/quit") do
    IO.puts("Goodbye!")
    :ok
  end

  defp handle_input(_agent, "/exit") do
    IO.puts("Goodbye!")
    System.halt(0)
  end

  defp handle_input(agent, "") do
    chat_loop(agent)
  end

  defp handle_input(agent, message) do
    SkillKit.send_message(agent, message)
    receive_response()
    chat_loop(agent)
  end

  defp receive_response do
    receive do
      %Delta{text: text} ->
        IO.write(text)
        receive_response()

      %AssistantMessage{} ->
        IO.puts("\n")

      _other ->
        receive_response()
    after
      30_000 ->
        IO.puts("\n[timeout waiting for response]")
    end
  end

  defp select_and_chat(username, owner) do
    personas = list_available_personas()

    if personas == [] do
      IO.puts("No personas available. Use --manage to create one.")
      System.halt(0)
    end

    IO.puts("\nEnter persona name to chat (or /quit to exit):")
    choice = read_persona_choice()

    run_persona_chat(username, choice, owner)
  end

  defp read_persona_choice do
    case IO.gets("> ") do
      :eof ->
        System.halt(0)

      input ->
        choice = String.trim(input)
        if choice == "/quit", do: System.halt(0)
        choice
    end
  end

  defp list_available_personas do
    case File.ls(@personas_dir) do
      {:ok, entries} ->
        personas =
          entries
          |> Enum.filter(&File.dir?(Path.join(@personas_dir, &1)))
          |> Enum.filter(&File.exists?(Path.join([@personas_dir, &1, "AGENT.md"])))

        Enum.each(personas, &print_persona/1)

        personas

      {:error, :enoent} ->
        []
    end
  end

  defp print_persona(name) do
    agent_path = Path.join([@personas_dir, name, "AGENT.md"])

    case Definition.parse(agent_path) do
      {:ok, defn} -> IO.puts("  - #{defn.name}: #{defn.description}")
      _ -> IO.puts("  - #{name}: (could not parse)")
    end
  end

  defp owner?(username) do
    case File.read(@config_file) do
      {:ok, content} ->
        check_owner(content, username)

      {:error, :enoent} ->
        register_owner(username)
    end
  end

  defp check_owner(content, username) do
    case Jason.decode(content) do
      {:ok, %{"owner" => owner}} -> owner == username
      _ -> register_owner(username)
    end
  end

  defp register_owner(username) do
    File.mkdir_p!(@data_dir)
    File.write!(@config_file, Jason.encode!(%{"owner" => username}))
    IO.puts("Registered #{username} as the owner.")
    true
  end
end
