defmodule SkillKit.Backend.Filesystem do
  @moduledoc """
  Backend that loads skills from `.skill.md` files on disk.

  Scans configured directories recursively for `**/*.skill.md` files,
  parses each via `SkillKit.Backend.Filesystem.Parser`, and returns
  the successfully loaded skills. Malformed files are skipped with
  a warning.

  ## Configuration

      {SkillKit.Backend.Filesystem, dirs: ["/path/to/skills", "/other/path"]}

  ## Options

  - `:dirs` (required) — list of directory paths to scan recursively
  """

  @behaviour SkillKit.Backend

  require Logger

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
