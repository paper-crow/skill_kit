defmodule SkillKit.Kit.Local do
  @moduledoc """
  Provider that loads kits from filesystem directories.
  Each directory becomes a Kit containing skills and agent definitions.
  """

  @behaviour SkillKit.Kit.Provider

  alias SkillKit.Agent.Definition
  alias SkillKit.Kit
  alias SkillKit.Kit.Local.Parser

  require Logger

  @impl true
  def load_kits(config) do
    case Keyword.fetch(config, :dir) do
      {:ok, dir} -> load_single_dir(dir)
      :error -> load_multiple_dirs(config)
    end
  end

  defp load_single_dir(dir) do
    if File.dir?(dir) do
      {:ok, [load_kit(dir)]}
    else
      {:ok, []}
    end
  end

  defp load_multiple_dirs(config) do
    dirs = Keyword.fetch!(config, :dirs)

    kits =
      dirs
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&load_kit/1)

    {:ok, kits}
  end

  defp load_kit(dir) do
    {skills, skill_errors} = load_skills_from(dir)
    {agents, agent_errors} = load_agents_from(dir)
    {root_agent, root_errors} = load_root_agent(dir)
    errors = skill_errors ++ agent_errors ++ root_errors

    if errors != [] do
      error_summary =
        Enum.map_join(errors, ", ", fn {source, reason} ->
          "#{source}: #{inspect(reason)}"
        end)

      Logger.warning(
        "SkillKit: kit '#{Path.basename(dir)}' — #{length(errors)} skipped (#{error_summary})"
      )
    end

    %Kit{name: Path.basename(dir), skills: skills, agents: agents, root_agent: root_agent}
  end

  defp load_skills_from(dir) do
    dir
    |> Path.join("**/*.skill.md")
    |> Path.wildcard()
    |> Enum.reduce({[], []}, fn file, {skills, errors} ->
      case Parser.load_file(file) do
        {:ok, skill} -> {[skill | skills], errors}
        {:error, reason} -> {skills, [{Path.basename(file), reason} | errors]}
      end
    end)
  end

  defp load_root_agent(dir) do
    root_path = Path.join(dir, "AGENT.md")

    if File.exists?(root_path) do
      parse_root_agent(root_path)
    else
      {nil, []}
    end
  end

  defp parse_root_agent(path) do
    case Definition.parse(path) do
      {:ok, agent} -> {agent, []}
      {:error, reason} -> {nil, [{"AGENT.md", reason}]}
    end
  end

  defp load_agents_from(dir) do
    dir
    |> discover_agent_files()
    |> Enum.reduce({[], []}, &load_agent_file/2)
  end

  defp discover_agent_files(dir) do
    dir
    |> Path.join("**/AGENT.md")
    |> Path.wildcard()
    |> Enum.reject(&root_agent_path?(dir, &1))
  end

  defp root_agent_path?(dir, path) do
    Path.dirname(path) == dir
  end

  defp load_agent_file(file, {agents, errors}) do
    case Definition.parse(file) do
      {:ok, agent} -> {[agent | agents], errors}
      {:error, reason} -> {agents, [{Path.basename(Path.dirname(file)), reason} | errors]}
    end
  end
end
