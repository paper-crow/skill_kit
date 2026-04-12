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

  alias SkillKit.Agent
  alias SkillKit.Kit
  alias SkillKit.Kit.Local.Parser
  alias SkillKit.Storage

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
    case Storage.list(parent_dir) do
      {:ok, entries} ->
        kits =
          entries
          |> Enum.reject(&hidden?/1)
          |> Enum.map(&Path.join(parent_dir, &1))
          |> Enum.filter(&Storage.dir?/1)
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
        "SkillKit: skipping '#{Path.basename(dir)}' — no AGENT.md, skills/, or agents/ found"
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
      not Storage.dir?(dir) -> {:ok, []}
      valid_kit?(dir) -> {:ok, [load_kit(dir)]}
      true -> {:error, :invalid_kit}
    end
  end

  defp valid_kit?(dir) do
    Storage.exists?(Path.join(dir, "AGENT.md")) or
      Storage.dir?(Path.join(dir, "skills")) or
      Storage.dir?(Path.join(dir, "agents"))
  end

  defp load_kit(dir) do
    {skills, skill_errors} = load_skills(dir)
    {subagents, agent_errors} = load_subagents(dir)
    {agent, root_errors} = load_agent(dir)
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

    %Kit{name: Path.basename(dir), skills: skills, subagents: subagents, agent: agent}
  end

  # -------------------------------------------------------------------
  # Skills: skills/*/SKILL.md (no recursion)
  # -------------------------------------------------------------------

  defp load_skills(dir) do
    skills_dir = Path.join(dir, "skills")

    if Storage.dir?(skills_dir) do
      load_skill_dirs(skills_dir)
    else
      {[], []}
    end
  end

  defp load_skill_dirs(skills_dir) do
    case Storage.list(skills_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(skills_dir, &1))
        |> Enum.filter(&Storage.dir?/1)
        |> Enum.reduce({[], []}, &load_skill_dir/2)

      {:error, _} ->
        {[], []}
    end
  end

  defp load_skill_dir(skill_dir, {skills, errors}) do
    skill_md = Path.join(skill_dir, "SKILL.md")

    if Storage.exists?(skill_md) do
      case Parser.load_file(skill_md) do
        {:ok, skill} -> {[skill | skills], errors}
        {:error, reason} -> {skills, [{Path.basename(skill_dir), reason} | errors]}
      end
    else
      {skills, errors}
    end
  end

  # -------------------------------------------------------------------
  # Subagents: agents/*.md (flat, no recursion)
  # -------------------------------------------------------------------

  defp load_subagents(dir) do
    agents_dir = Path.join(dir, "agents")

    if Storage.dir?(agents_dir) do
      case Storage.list(agents_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&Path.join(agents_dir, &1))
          |> Enum.reduce({[], []}, &load_agent_file/2)

        {:error, _} ->
          {[], []}
      end
    else
      {[], []}
    end
  end

  defp load_agent_file(file, {agents, errors}) do
    with {:ok, content} <- Storage.read(file),
         {:ok, agent} <- Agent.parse(content) do
      {[agent | agents], errors}
    else
      {:error, reason} -> {agents, [{Path.basename(file), reason} | errors]}
    end
  end

  # -------------------------------------------------------------------
  # Agent: AGENT.md at kit root
  # -------------------------------------------------------------------

  defp load_agent(dir) do
    root_path = Path.join(dir, "AGENT.md")

    if Storage.exists?(root_path) do
      with {:ok, content} <- Storage.read(root_path),
           {:ok, agent} <- Agent.parse(content) do
        {agent, []}
      else
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
