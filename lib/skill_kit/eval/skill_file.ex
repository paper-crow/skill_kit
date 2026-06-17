defmodule SkillKit.Eval.SkillFile do
  @moduledoc false
  # Kit provider that loads a single `SKILL.md` file by path into a one-skill
  # kit. Used by `SkillKit.Eval` to infer the skill under test from an
  # `EVAL.md` that sits next to its `SKILL.md`.

  @behaviour SkillKit.Kit.Provider

  alias SkillKit.Kit
  alias SkillKit.Kit.Local.Parser

  @impl SkillKit.Kit.Provider
  def load_kits(config) do
    path = Keyword.fetch!(config, :path)

    case Parser.load_file(path) do
      {:ok, skill} -> {:ok, [kit(skill)]}
      {:error, _} = error -> error
    end
  end

  @impl SkillKit.Kit.Provider
  def list_kits(config), do: load_kits(config)

  @impl SkillKit.Kit.Provider
  def get_kit(config, name) do
    case list_kits(config) do
      {:ok, kits} -> find_kit(kits, name)
      {:error, _} = error -> error
    end
  end

  defp kit(skill), do: %Kit{name: skill.namespace || "eval", skills: [skill]}

  defp find_kit(kits, name) do
    case Enum.find(kits, &(&1.name == name)) do
      nil -> {:error, :not_found}
      kit -> {:ok, kit}
    end
  end
end
