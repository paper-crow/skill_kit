defmodule SkillKit.Agent.Discovery do
  @moduledoc """
  Discovers agent definitions from filesystem directories.

  Scans directories for subdirectories containing `AGENT.md` files,
  parses them into `%Agent.Definition{}` structs. Directories are
  scanned in order — first-discovered-wins on name conflicts
  (project-scoped agents override user-scoped agents).
  """

  alias SkillKit.Agent.Definition

  require Logger

  @doc """
  Discovers agent definitions from the given directories.

  Scans each directory for immediate subdirectories containing
  an `AGENT.md` file. Returns `{:ok, [%Definition{}]}`.

  Invalid files are logged and skipped. Nonexistent directories
  are silently ignored.
  """
  @spec discover([Path.t()]) :: {:ok, [Definition.t()]}
  def discover(dirs) do
    {definitions, _seen} =
      dirs
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&scan_dir/1)
      |> Enum.reduce({[], MapSet.new()}, fn definition, {acc, seen} ->
        if MapSet.member?(seen, definition.name) do
          {acc, seen}
        else
          {[definition | acc], MapSet.put(seen, definition.name)}
        end
      end)

    {:ok, Enum.reverse(definitions)}
  end

  defp scan_dir(dir) do
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.join(&1, "AGENT.md"))
    |> Enum.filter(&File.exists?/1)
    |> Enum.flat_map(fn path ->
      case Definition.parse(path) do
        {:ok, definition} ->
          [definition]

        {:error, reason} ->
          Logger.warning("SkillKit: skipped #{path}: #{inspect(reason)}")
          []
      end
    end)
  end
end
