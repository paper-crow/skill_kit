defmodule SkillKit.Kit.Local do
  @moduledoc """
  Provider that loads kits from filesystem directories.

  A kit directory may contain:
  - `AGENT.md` at root — agent identity (used when loaded via `agent:`)
  - `skills/` — immediate subdirectories, each with a `SKILL.md`
  - `agents/` — flat `.md` files defining delegatable sub-agents

  ## Directory modes

  - `dir: "path"` — loads a single kit from the directory
  - `dir: "path/*"` — loads each immediate child of `path` as a separate kit
  """

  @behaviour SkillKit.Kit.Provider

  alias SkillKit.Agent.Definition
  alias SkillKit.Kit
  alias SkillKit.Kit.Local.Parser

  require Logger

  @impl true
  def load_kits(config) do
    dir = Keyword.fetch!(config, :dir)

    if wildcard?(dir) do
      load_wildcard(String.trim_trailing(dir, "/*"))
    else
      load_single(dir)
    end
  end

  @impl true
  def list_kits(config), do: load_kits(config)

  @impl true
  def get_kit(config, name) do
    case list_kits(config) do
      {:ok, kits} -> find_kit_by_name(kits, name)
      error -> error
    end
  end

  # -------------------------------------------------------------------
  # Wildcard expansion
  # -------------------------------------------------------------------

  defp wildcard?(dir), do: String.ends_with?(dir, "/*")

  defp load_wildcard(parent_dir) do
    case File.ls(parent_dir) do
      {:ok, entries} ->
        kits =
          entries
          |> Enum.reject(&hidden?/1)
          |> Enum.map(&Path.join(parent_dir, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.flat_map(&load_wildcard_child/1)

        {:ok, kits}

      {:error, :enoent} ->
        {:ok, []}
    end
  end

  defp load_wildcard_child(dir) do
    if valid_kit?(dir) do
      [load_kit(dir)]
    else
      Logger.warning(
        "SkillKit: skipping '#{Path.basename(dir)}' — no SKILL.md, skills/, or AGENT.md found"
      )

      []
    end
  end

  defp hidden?(name), do: String.starts_with?(name, ".")

  # -------------------------------------------------------------------
  # Single kit loading
  # -------------------------------------------------------------------

  defp load_single(dir) do
    cond do
      not File.dir?(dir) -> {:ok, []}
      valid_kit?(dir) -> {:ok, [load_kit(dir)]}
      true -> {:error, :invalid_kit}
    end
  end

  defp valid_kit?(dir) do
    File.exists?(Path.join(dir, "AGENT.md")) or
      File.dir?(Path.join(dir, "skills")) or
      File.dir?(Path.join(dir, "agents"))
  end

  defp load_kit(dir) do
    {skills, skill_errors} = load_skills(dir)
    {agents, agent_errors} = load_agents(dir)
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

  # -------------------------------------------------------------------
  # Skills: skills/*/SKILL.md (no recursion)
  # -------------------------------------------------------------------

  defp load_skills(dir) do
    skills_dir = Path.join(dir, "skills")

    if File.dir?(skills_dir) do
      load_skill_dirs(skills_dir)
    else
      {[], []}
    end
  end

  defp load_skill_dirs(skills_dir) do
    case File.ls(skills_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(skills_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.reduce({[], []}, &load_skill_dir/2)

      {:error, _} ->
        {[], []}
    end
  end

  defp load_skill_dir(skill_dir, {skills, errors}) do
    skill_md = Path.join(skill_dir, "SKILL.md")

    if File.exists?(skill_md) do
      case Parser.load_file(skill_md) do
        {:ok, skill} -> {[skill | skills], errors}
        {:error, reason} -> {skills, [{Path.basename(skill_dir), reason} | errors]}
      end
    else
      {skills, errors}
    end
  end

  # -------------------------------------------------------------------
  # Agents: agents/*.md (flat, no recursion)
  # -------------------------------------------------------------------

  defp load_agents(dir) do
    agents_dir = Path.join(dir, "agents")

    if File.dir?(agents_dir) do
      agents_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.reduce({[], []}, &load_agent_file/2)
    else
      {[], []}
    end
  end

  defp load_agent_file(file, {agents, errors}) do
    case Definition.parse(file) do
      {:ok, agent} -> {[agent | agents], errors}
      {:error, reason} -> {agents, [{Path.basename(file), reason} | errors]}
    end
  end

  # -------------------------------------------------------------------
  # Root agent: AGENT.md at kit root
  # -------------------------------------------------------------------

  defp load_root_agent(dir) do
    root_path = Path.join(dir, "AGENT.md")

    if File.exists?(root_path) do
      case Definition.parse(root_path) do
        {:ok, agent} -> {agent, []}
        {:error, reason} -> {nil, [{"AGENT.md", reason}]}
      end
    else
      {nil, []}
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp find_kit_by_name(kits, name) do
    case Enum.find(kits, &(&1.name == name)) do
      nil -> {:error, :not_found}
      kit -> {:ok, kit}
    end
  end
end
