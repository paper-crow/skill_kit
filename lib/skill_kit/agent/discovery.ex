defmodule SkillKit.Agent.Discovery do
  @moduledoc """
  Loads agent definitions from backends via Kit unpacking.
  """

  alias SkillKit.Agent.Definition

  require Logger

  @spec discover([{module(), keyword()}]) :: {:ok, [Definition.t()]}
  def discover(backends) do
    {definitions, _seen} =
      backends
      |> Enum.flat_map(&load_from_backend/1)
      |> Enum.reduce({[], MapSet.new()}, fn definition, {acc, seen} ->
        if MapSet.member?(seen, definition.name) do
          {acc, seen}
        else
          {[definition | acc], MapSet.put(seen, definition.name)}
        end
      end)

    {:ok, Enum.reverse(definitions)}
  end

  defp load_from_backend({mod, config}) do
    case mod.load_kits(config) do
      {:ok, kits} -> Enum.flat_map(kits, & &1.agents)
      {:error, reason} ->
        Logger.warning("SkillKit: agent backend #{inspect(mod)} failed: #{inspect(reason)}")
        []
    end
  end
end
