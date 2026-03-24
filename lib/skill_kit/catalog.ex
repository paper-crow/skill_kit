defmodule SkillKit.Catalog do
  @moduledoc """
  Public API for skill discovery, activation, and authorization filtering.

  Wraps `SkillKit.Registry` with scope-based authorization. Consumers use
  the Catalog for all skill interactions — the Registry is internal.

  ## Progressive disclosure tiers

  1. **Discovery** — `list_skills/2` returns authorized skill metadata
  2. **Activation** — `activate/4` renders the skill body for LLM context
  3. **Execution** — handled by `SkillKit.Handler` (separate concern)
  """

  alias SkillKit.Authorization
  alias SkillKit.Registry
  alias SkillKit.Skill

  @doc """
  Lists skills the caller is authorized to see.

  When `scopes` option is provided, filters out skills whose
  `required_scope` is not covered by the granted scopes.
  Skills with empty `required_scope` are always included.

  When no `scopes` option is provided, returns all skills unfiltered
  (useful for admin/internal use cases).
  """
  def list_skills(server, opts \\ []) do
    all_skills = Registry.list_skills(server)

    case Keyword.fetch(opts, :scopes) do
      {:ok, granted_scopes} ->
        Enum.filter(all_skills, fn skill ->
          Authorization.authorized?(skill, granted_scopes)
        end)

      :error ->
        all_skills
    end
  end

  @doc """
  Retrieves a skill by name, checking authorization.

  Returns `{:ok, skill}` if found and authorized.
  Returns `{:error, :not_found}` if the skill doesn't exist.
  Returns `{:error, :unauthorized}` if the caller lacks required scopes.

  When no `scopes` option is provided, skips authorization check.
  """
  def get_skill(server, name, opts \\ []) do
    with {:ok, skill} <- Registry.get_skill(server, name) do
      maybe_authorize(skill, opts)
    end
  end

  defp maybe_authorize(skill, opts) do
    case Keyword.fetch(opts, :scopes) do
      {:ok, granted_scopes} -> Authorization.authorize(skill, granted_scopes)
      :error -> {:ok, skill}
    end
  end

  @doc """
  Activates a skill — retrieves it, checks authorization, and renders
  the body with the provided arguments.

  This is tier 2 of progressive disclosure: the full skill body is
  rendered with argument substitutions and returned ready for LLM context.
  """
  def activate(server, name, args, opts \\ []) do
    case get_skill(server, name, opts) do
      {:ok, skill} -> Skill.render(skill, args)
      error -> error
    end
  end

  @doc "Registers a skill. Pass-through to Registry."
  def register(server, %Skill{} = skill) do
    Registry.register(server, skill)
  end

  @doc "Unregisters a skill by name. Pass-through to Registry."
  def unregister(server, name) do
    Registry.unregister(server, name)
  end
end
