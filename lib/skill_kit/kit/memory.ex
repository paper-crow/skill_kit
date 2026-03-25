defmodule SkillKit.Kit.Memory do
  @moduledoc """
  In-memory kit provider for testing and dynamic skill injection.

  Backed by an `Agent`. Stores kits directly or wraps individual
  skills into auto-named kits by namespace.

      {:ok, provider} = Kit.Memory.start_link([])
      Kit.Memory.put(provider, %Skill{name: "ns:hello", body: "..."})
      {:ok, kits} = Kit.Memory.list_kits(provider: provider)
  """

  @behaviour SkillKit.Kit.Provider

  alias SkillKit.Kit
  alias SkillKit.Skill

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @spec put_kit(pid() | atom(), Kit.t()) :: :ok
  def put_kit(provider, %Kit{} = kit) do
    Agent.update(provider, &Map.put(&1, kit.name, kit))
  end

  @spec put(pid() | atom(), Skill.t()) :: :ok
  def put(provider, %Skill{} = skill) do
    namespace = extract_namespace(skill.name)

    Agent.update(provider, fn state ->
      upsert_skill(state, namespace, skill)
    end)
  end

  @spec delete(pid() | atom(), String.t()) :: :ok
  def delete(provider, skill_name) do
    namespace = extract_namespace(skill_name)

    Agent.update(provider, fn state ->
      remove_skill(state, namespace, skill_name)
    end)
  end

  @impl SkillKit.Kit.Provider
  def list_kits(config) do
    provider = Keyword.fetch!(config, :provider)
    kits = Agent.get(provider, &Map.values/1)
    {:ok, kits}
  end

  @impl SkillKit.Kit.Provider
  def get_kit(config, name) do
    provider = Keyword.fetch!(config, :provider)
    result = Agent.get(provider, &Map.get(&1, name))
    resolve_kit(result)
  end

  defp resolve_kit(nil), do: {:error, :not_found}
  defp resolve_kit(kit), do: {:ok, kit}

  defp upsert_skill(state, namespace, skill) do
    kit = Map.get(state, namespace, %Kit{name: namespace})
    existing = Enum.reject(kit.skills, &(&1.name == skill.name))
    updated = %{kit | skills: existing ++ [skill]}
    Map.put(state, namespace, updated)
  end

  defp remove_skill(state, namespace, skill_name) do
    case Map.get(state, namespace) do
      nil -> state
      kit -> apply_skill_removal(state, namespace, kit, skill_name)
    end
  end

  defp apply_skill_removal(state, namespace, kit, skill_name) do
    remaining = Enum.reject(kit.skills, &(&1.name == skill_name))

    if remaining == [] do
      Map.delete(state, namespace)
    else
      Map.put(state, namespace, %{kit | skills: remaining})
    end
  end

  defp extract_namespace(name) do
    case String.split(name, ":", parts: 2) do
      [namespace, _] -> namespace
      [bare] -> bare
    end
  end
end
