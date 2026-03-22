defmodule SkillKit.Backend.Filesystem do
  @moduledoc """
  Backend that loads skills and agent definitions from disk.

  Scans configured directories recursively for `**/*.skill.md` files
  and for subdirectories containing `AGENT.md` files.

  ## Configuration

      {SkillKit.Backend.Filesystem, dirs: ["/path/to/workspace", "/other/path"]}

  ## Options

  - `:dirs` (required) — list of directory paths to scan
  """

  @behaviour SkillKit.Backend

  require Logger

  alias SkillKit.Agent.Definition
  alias SkillKit.Backend.Filesystem.Parser

  @impl true
  def load_skills(config) do
    dirs = Keyword.fetch!(config, :dirs)

    {skills, errors} =
      dirs
      |> Enum.flat_map(&discover_skill_files/1)
      |> Enum.reduce({[], []}, &load_skill_file/2)

    if errors != [] do
      error_summary =
        Enum.map_join(errors, ", ", fn {source, reason} ->
          "#{source}: #{inspect(reason)}"
        end)

      Logger.warning(
        "SkillKit: loaded #{length(skills)} skills, #{length(errors)} skipped (#{error_summary})"
      )
    end

    {:ok, skills}
  end

  @impl true
  def load_agents(config) do
    dirs = Keyword.get(config, :dirs, [])

    {agents, errors} =
      dirs
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&discover_agent_files/1)
      |> Enum.reduce({[], []}, &load_agent_file/2)

    if errors != [] do
      error_summary =
        Enum.map_join(errors, ", ", fn {source, reason} ->
          "#{source}: #{inspect(reason)}"
        end)

      Logger.warning(
        "SkillKit: loaded #{length(agents)} agents, #{length(errors)} skipped (#{error_summary})"
      )
    end

    {:ok, agents}
  end

  defp discover_agent_files(dir) do
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.join(&1, "AGENT.md"))
    |> Enum.filter(&File.exists?/1)
  end

  defp load_agent_file(file, {agents_acc, errors_acc}) do
    case Definition.parse(file) do
      {:ok, agent} -> {[agent | agents_acc], errors_acc}
      {:error, reason} -> {agents_acc, [{Path.basename(Path.dirname(file)), reason} | errors_acc]}
    end
  end

  defp discover_skill_files(dir) do
    Path.join(dir, "**/*.skill.md") |> Path.wildcard()
  end

  defp load_skill_file(file, {skills_acc, errors_acc}) do
    case Parser.load_file(file) do
      {:ok, skill} -> {[skill | skills_acc], errors_acc}
      {:error, reason} -> {skills_acc, [{Path.basename(file), reason} | errors_acc]}
    end
  end
end
