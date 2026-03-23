defmodule Mix.Tasks.SkillKit.Chat do
  @moduledoc """
  Interactive chat session with a SkillKit agent.

      mix skill_kit.chat            # select agent interactively
      mix skill_kit.chat neve       # start specific agent
      mix skill_kit.chat researcher
  """

  use Mix.Task

  alias SkillKit.Agent.Definition

  @shortdoc "Start an interactive agent chat session"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    api_key = System.get_env("ANTHROPIC_API_KEY")

    unless api_key do
      Mix.shell().error("Set ANTHROPIC_API_KEY environment variable")
      exit({:shutdown, 1})
    end

    agents_dir = System.get_env("SKILL_KIT_AGENTS", "examples/agents")
    skills_dir = System.get_env("SKILL_KIT_SKILLS", "examples/skills")

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

    {:ok, definition} = Definition.parse(agent_md)
    definition = %{definition | workspace: File.cwd!()}

    {:ok, agent} =
      SkillKit.start_agent(definition,
        sources: [{SkillKit.Backend.Filesystem, dirs: [skills_dir]}],
        provider: {SkillKit.LLM.Anthropic, [api_key: api_key]},
        caller: self()
      )

    IO.puts(
      IO.ANSI.format([
        :bright,
        "\n#{definition.name}",
        :reset,
        :faint,
        " — #{definition.description}"
      ])
    )

    IO.puts(IO.ANSI.format([:faint, "type 'exit' to quit\n"]))

    chat_loop(agent, definition.name)

    SkillKit.stop_agent(agent)
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

    case Definition.parse(agent_md) do
      {:ok, d} -> d.description
      _ -> ""
    end
  end

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

        cond do
          prompt == "exit" ->
            IO.puts("Goodbye.")

          prompt == "" ->
            chat_loop(agent, agent_name)

          true ->
            :ok = SkillKit.send_message(agent, prompt)
            receive_response(agent_name)
            chat_loop(agent, agent_name)
        end
    end
  end

  defp receive_response(agent_name) do
    receive do
      {:skill_kit, ^agent_name, {:delta, text}} ->
        IO.write(text)
        receive_response(agent_name)

      {:skill_kit, ^agent_name, {:tool_call, name, input}} ->
        IO.puts(IO.ANSI.format([:faint, "  ↳ #{name}(#{format_input(name, input)})"]))
        receive_response(agent_name)

      {:skill_kit, ^agent_name, {:tool_result, _name, _content, _is_error}} ->
        receive_response(agent_name)

      {:skill_kit, ^agent_name, {:response, _text}} ->
        IO.puts("\n")
        wait_for_follow_up(agent_name)

      {:skill_kit, ^agent_name, {:error, reason}} ->
        IO.puts("\n[error] #{inspect(reason)}\n")
    after
      120_000 ->
        IO.puts("\n[timeout]\n")
    end
  end

  defp format_input("bash", %{"command" => cmd}), do: cmd
  defp format_input("activate_skill", %{"name" => name}), do: name
  defp format_input(_name, input) when map_size(input) == 0, do: ""
  defp format_input(_name, input), do: inspect(input, limit: 3)

  defp wait_for_follow_up(agent_name) do
    receive do
      {:skill_kit, ^agent_name, {:delta, _text}} = msg ->
        IO.puts("--- subagent result arrived ---")
        send(self(), msg)
        receive_response(agent_name)
    after
      5_000 ->
        :ok
    end
  end
end
