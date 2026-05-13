defmodule Mix.Tasks.SkillKit.Ralph do
  @moduledoc """
  Run a Ralph loop against a TODO file.

      # Loop on an existing TODO.md in the current directory
      mix skill_kit.ralph TODO.md

      # Generate TODO.md from a prompt, then loop
      mix skill_kit.ralph TODO.md --prompt "Add JSON parsing to lib/foo.ex with tests"

      # Choose a different agent (default: ralph)
      mix skill_kit.ralph TODO.md --agent some-other-ralph

      # Operate in a different working directory
      mix skill_kit.ralph TODO.md --cwd path/to/project

  ## How it works

  This task is a thin driver. The Ralph contract lives in skills:

    * `examples/agents/ralph/AGENT.md` — agent identity, routes user
      requests to the right skill.
    * `examples/agents/ralph/skills/plan/SKILL.md` — generates a TODO
      file from a goal.
    * `examples/agents/ralph/skills/iterate/SKILL.md` — does one
      iteration: pick top unchecked item, do it, mark [x], commit.

  The task sends a trigger message per turn — "Plan a TODO file at
  PATH for: GOAL" or "Iterate on PATH" — and waits for the agent to
  echo the skill's final word: `PLANNED`, `CONTINUE`, or `DONE`. The
  loop exits on `DONE` (or on an `%Event.Error{}`). There is no
  iteration cap and no per-turn timeout — pacing is handled by
  `Anthropic.Client`'s 429 retry.

  See `guides/ralph-loop.md` for the design.
  """

  use Mix.Task

  alias SkillKit.Event.Delta
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Types.AssistantMessage

  @shortdoc "Run a Ralph loop on a TODO file"

  @switches [agent: :string, prompt: :string, cwd: :string]

  @impl true
  def run(args) do
    load_dotenv()
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, switches: @switches)

    cwd = opts[:cwd] || File.cwd!()
    todo_path = positional |> todo_path_from() |> Path.expand(cwd)
    agent_dir = locate_agent!(opts[:agent] || "ralph")

    {:ok, agent} =
      SkillKit.start_agent(agent_dir,
        tools: [{SkillKit.Tools.Shell, cwd: cwd}],
        caller: self()
      )

    maybe_plan(agent, todo_path, opts[:prompt])
    ensure_todo!(todo_path, agent)

    result = loop(agent, todo_path, 1)
    SkillKit.stop_agent(agent)

    report(result)
  end

  defp todo_path_from([path | _]), do: path
  defp todo_path_from([]), do: "TODO.md"

  defp locate_agent!(name) do
    agents_dir = System.get_env("SKILL_KIT_AGENTS", "examples/agents")
    dir = Path.join(agents_dir, name)

    case File.dir?(dir) do
      true -> dir
      false -> agent_missing!(dir)
    end
  end

  defp agent_missing!(dir) do
    Mix.shell().error("Agent not found at #{dir}")
    exit({:shutdown, 1})
  end

  defp maybe_plan(_agent, _todo_path, nil), do: :ok

  defp maybe_plan(agent, todo_path, goal) do
    IO.puts(IO.ANSI.format([:bright, "\n--- planning ---", :reset]))
    trigger = "Plan a TODO file at #{todo_path} for this goal: #{goal}"
    :ok = SkillKit.send_message(agent, trigger)

    case wait_for_turn() do
      {:ok, _msg} -> :ok
      {:error, reason} -> abort!(agent, "planning failed: #{inspect(reason)}")
    end
  end

  defp ensure_todo!(todo_path, agent) do
    case File.exists?(todo_path) do
      true -> :ok
      false -> abort!(agent, "TODO file not found at #{todo_path}. Use --prompt to generate one.")
    end
  end

  defp abort!(agent, reason) do
    SkillKit.stop_agent(agent)
    Mix.shell().error(reason)
    exit({:shutdown, 1})
  end

  defp loop(agent, todo_path, iter) do
    IO.puts(IO.ANSI.format([:bright, :magenta, "\n--- iter #{iter} ---", :reset]))
    :ok = SkillKit.send_message(agent, "Iterate on #{todo_path}.")

    case wait_for_turn() do
      {:ok, %AssistantMessage{content: content}} -> next_step(content, agent, todo_path, iter)
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_step(content, agent, todo_path, iter) do
    case String.trim(content) do
      "DONE" -> :done
      _ -> loop(agent, todo_path, iter + 1)
    end
  end

  defp wait_for_turn do
    receive do
      %AssistantMessage{} = msg ->
        {:ok, msg}

      %EventError{reason: reason} ->
        {:error, reason}

      %Delta{text: text} ->
        IO.write(text)
        wait_for_turn()

      %ToolCallComplete{name: name, input: input} ->
        IO.puts(IO.ANSI.format([:faint, "\n  ↳ #{name}(#{format_input(input)})", :reset]))
        wait_for_turn()

      _other ->
        wait_for_turn()
    end
  end

  defp format_input(%{"command" => cmd}), do: cmd
  defp format_input(%{"name" => name}), do: name
  defp format_input(input) when is_map(input) and map_size(input) == 0, do: ""
  defp format_input(input), do: inspect(input, limit: 3)

  defp report(:done) do
    IO.puts(IO.ANSI.format([:green, "\nRalph converged.\n", :reset]))
  end

  defp report({:error, reason}) do
    IO.puts(IO.ANSI.format([:red, "\nRalph failed: ", :reset, inspect(reason), "\n"]))
    exit({:shutdown, 1})
  end

  # --- dotenv (mirror of skill_kit.chat) -----------------------------------

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
end
