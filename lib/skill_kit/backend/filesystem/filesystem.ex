defmodule SkillKit.Backend.Filesystem do
  @moduledoc """
  Backend that loads kits from filesystem directories.
  Each directory becomes a Kit containing skills and agent definitions.
  """

  @behaviour SkillKit.Backend

  alias SkillKit.Agent.Definition
  alias SkillKit.Backend.Filesystem.Parser
  alias SkillKit.Kit

  require Logger

  @impl true
  def load_kits(config) do
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
    errors = skill_errors ++ agent_errors

    if errors != [] do
      error_summary =
        Enum.map_join(errors, ", ", fn {source, reason} ->
          "#{source}: #{inspect(reason)}"
        end)

      Logger.warning(
        "SkillKit: kit '#{Path.basename(dir)}' — #{length(errors)} skipped (#{error_summary})"
      )
    end

    %Kit{name: Path.basename(dir), skills: skills, agents: agents}
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

  defp load_agents_from(dir) do
    dir
    |> discover_agent_files()
    |> Enum.reduce({[], []}, &load_agent_file/2)
  end

  defp discover_agent_files(dir) do
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.join(&1, "AGENT.md"))
    |> Enum.filter(&File.exists?/1)
  end

  defp load_agent_file(file, {agents, errors}) do
    case Definition.parse(file) do
      {:ok, agent} -> {[agent | agents], errors}
      {:error, reason} -> {agents, [{Path.basename(Path.dirname(file)), reason} | errors]}
    end
  end
end
