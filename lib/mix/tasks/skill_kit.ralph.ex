defmodule Mix.Tasks.SkillKit.Ralph do
  @moduledoc """
  Run a Ralph loop against a TODO file.

      # Loop on an existing TODO.md in the current directory
      mix skill_kit.ralph TODO.md

      # Generate TODO.md from a prompt, then loop
      mix skill_kit.ralph TODO.md --prompt "Add JSON parsing to lib/foo.ex with tests"

      # Choose a different agent (default: fixer)
      mix skill_kit.ralph TODO.md --agent neve

      # Operate in a different working directory
      mix skill_kit.ralph TODO.md --cwd path/to/project

  ## How it works

  Each iteration sends the same prompt: read the TODO file, pick the
  top unchecked item under `## MVP`, do it, mark it `[x]`, commit. The
  loop exits when the agent replies `DONE` or when an error event
  arrives. There is no iteration cap and no per-turn timeout — pacing
  is handled by `Anthropic.Client`'s 429 retry.

  See `guides/ralph-loop.md` for the design.
  """

  use Mix.Task

  alias SkillKit.Event.Delta
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Types.AssistantMessage

  @shortdoc "Run a Ralph loop on a TODO file"

  @switches [agent: :string, prompt: :string, cwd: :string]

  @loop_prompt """
  Read the TODO file at <%= path %>.

  Pick the top item under `## MVP` whose checkbox is unchecked. Do it.
  Run `mix test` (or the project's equivalent) to verify. Mark the item
  `[x]`. Append any new subtasks you discovered to `## MVP`. Stage and
  commit; the commit message is the item text.

  Reply with exactly the word DONE — and nothing else — if and only if
  every line under `## MVP` starts with `[x]` AND tests pass.
  """

  @planner_prompt """
  Write a TODO file at <%= path %> for the goal below.

  GOAL:
  <%= goal %>

  Requirements:
    - One `## MVP` section using `- [ ]` checkboxes.
    - Each item must be verifiable (a test or check proves it done).
    - Each item must be roughly one iteration of work — small but real.
    - Order items by dependency.
    - Optional `## FUTURE` section for nice-to-haves.

  Use your shell tool to write the file. Reply "PLANNED" when done.
  """

  @impl true
  def run(args) do
    load_dotenv()
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, switches: @switches)

    todo_path = todo_path_from(positional)
    cwd = opts[:cwd] || File.cwd!()
    agent_dir = locate_agent!(opts[:agent] || "fixer")

    {:ok, agent} =
      SkillKit.start_agent(agent_dir,
        tools: [{SkillKit.Tools.Shell, cwd: cwd}],
        caller: self()
      )

    maybe_plan(agent, todo_path, opts[:prompt])
    ensure_todo!(cwd, todo_path, agent)

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
    IO.puts(IO.ANSI.format([:bright, "\n--- planning ---"]))
    prompt = render(@planner_prompt, path: todo_path, goal: goal)
    :ok = SkillKit.send_message(agent, prompt)

    case wait_for_turn() do
      {:ok, _msg} -> :ok
      {:error, reason} -> abort!(agent, "planning failed: #{inspect(reason)}")
    end
  end

  defp ensure_todo!(cwd, todo_path, agent) do
    full = Path.join(cwd, todo_path)

    case File.exists?(full) do
      true -> :ok
      false -> abort!(agent, "TODO file not found at #{full}. Use --prompt to generate one.")
    end
  end

  defp abort!(agent, reason) do
    SkillKit.stop_agent(agent)
    Mix.shell().error(reason)
    exit({:shutdown, 1})
  end

  defp loop(agent, todo_path, iter) do
    IO.puts(IO.ANSI.format([:bright, :magenta, "\n--- iter #{iter} ---", :reset]))
    prompt = render(@loop_prompt, path: todo_path)
    :ok = SkillKit.send_message(agent, prompt)

    case wait_for_turn() do
      {:ok, %AssistantMessage{content: content}} -> next_step(content, agent, todo_path, iter)
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_step("DONE" <> _, _agent, _todo_path, _iter), do: :done
  defp next_step(_content, agent, todo_path, iter), do: loop(agent, todo_path, iter + 1)

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
  defp format_input(input) when is_map(input) and map_size(input) == 0, do: ""
  defp format_input(input), do: inspect(input, limit: 3)

  defp report(:done) do
    IO.puts(IO.ANSI.format([:green, "\nRalph converged.\n", :reset]))
  end

  defp report({:error, reason}) do
    IO.puts(IO.ANSI.format([:red, "\nRalph failed: ", :reset, inspect(reason), "\n"]))
    exit({:shutdown, 1})
  end

  defp render(template, bindings) do
    Enum.reduce(bindings, template, &replace_binding/2)
  end

  defp replace_binding({key, value}, template) do
    String.replace(template, "<%= #{key} %>", to_string(value))
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
