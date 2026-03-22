defmodule SkillKit.Agent.Discovery do
  @moduledoc """
  Loads agent definitions from backends.

  Iterates over configured backends, calling `load_agents/1` on those
  that implement it. First-loaded-wins on name conflicts — backends
  listed first take priority.
  """

  alias SkillKit.Agent.Definition

  require Logger

  @doc """
  Loads agent definitions from the given backends.

  Each backend is a `{module, config}` tuple. Backends that don't
  implement `load_agents/1` are silently skipped. Failed backends
  are logged and skipped.

  Returns `{:ok, [%Definition{}]}` with first-loaded-wins dedup.
  """
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
    Code.ensure_loaded(mod)

    if function_exported?(mod, :load_agents, 1) do
      case mod.load_agents(config) do
        {:ok, agents} -> agents
        {:error, reason} ->
          Logger.warning("SkillKit: agent backend #{inspect(mod)} failed: #{inspect(reason)}")
          []
      end
    else
      []
    end
  end
end
