defmodule SkillKit.Authorization do
  @moduledoc """
  Pure-function authorization API for SkillKit.

  This module provides scope-based authorization for skills. It is a pure-function
  module — no process state, no GenServer, no registry coupling. All functions are
  safe to call from concurrent processes without synchronization.

  ## ALL-of Semantics

  Authorization uses ALL-of multi-scope semantics: a caller must hold **every**
  required scope in order to be authorized. Holding any subset is insufficient.

  Scope coverage uses `SkillKit.Scope.any_covers?/2` (OR primitive): a single
  granted wildcard scope (e.g. `"admin:*"`) can satisfy a required exact scope
  (e.g. `"admin:read"`). ALL-of wraps this OR primitive across each required scope.

  ## Error Signal Distinction

  - `{:error, :unauthorized}` — caller lacks required scopes
  - `{:error, reason}` — provider returned an error (passed through unchanged)
  - `{:error, :not_found}` — **never returned by this module**; that atom is
    exclusive to `SkillKit.Registry.get_skill/2`

  ## Usage

      # authorize/2 — direct scope list
      skill = %SkillKit.Skill{required_scope: ["admin:read"]}
      {:ok, ^skill} = SkillKit.Authorization.authorize(skill, ["admin:read", "admin:write"])
      {:error, :unauthorized} = SkillKit.Authorization.authorize(skill, ["tools:read"])

      # authorize/3 — provider-resolved scopes
      {:ok, ^skill} = SkillKit.Authorization.authorize(skill, MyApp.TokenProvider, %{token: "..."})
      {:error, :token_expired} = SkillKit.Authorization.authorize(skill, MyApp.TokenProvider, %{token: "expired"})

      # authorized?/2 — boolean convenience
      true = SkillKit.Authorization.authorized?(skill, ["admin:*"])
      false = SkillKit.Authorization.authorized?(skill, [])
  """

  alias SkillKit.{Scope, Skill}

  # ---------------------------------------------------------------------------
  # authorize/2 — direct mode
  # ---------------------------------------------------------------------------

  @doc """
  Authorizes `skill` given a flat list of granted scope strings.

  Returns `{:ok, skill}` when every required scope is covered by at least one
  granted scope (ALL-of semantics). Returns `{:error, :unauthorized}` when any
  required scope is not covered.

  Fast-paths to `{:ok, skill}` immediately when `required_scope` is `[]`.
  """
  @spec authorize(Skill.t(), [String.t()]) :: {:ok, Skill.t()} | {:error, :unauthorized}
  def authorize(%Skill{required_scope: []} = skill, _granted_scopes), do: {:ok, skill}

  def authorize(%Skill{required_scope: required} = skill, granted_scopes)
      when is_list(granted_scopes) do
    if Enum.all?(required, &Scope.any_covers?(granted_scopes, &1)) do
      {:ok, skill}
    else
      {:error, :unauthorized}
    end
  end

  # ---------------------------------------------------------------------------
  # authorize/3 — provider mode
  # ---------------------------------------------------------------------------

  @doc """
  Authorizes `skill` by resolving scopes via `provider.resolve_scopes(context)`.

  `provider` must be an atom (module name) implementing `SkillKit.AuthorizationProvider`.
  `context` is an opaque map passed through to the provider unchanged.

  Fast-paths to `{:ok, skill}` without calling the provider when `required_scope`
  is `[]`. When the provider returns `{:error, reason}`, that error passes through
  unchanged — it is never normalized to `{:error, :unauthorized}`.

  Provider exceptions are NOT rescued (let it crash).
  """
  @spec authorize(Skill.t(), module(), map()) ::
          {:ok, Skill.t()} | {:error, :unauthorized} | {:error, term()}
  def authorize(%Skill{required_scope: []} = skill, _provider, _context), do: {:ok, skill}

  def authorize(%Skill{} = skill, provider, context)
      when is_atom(provider) and is_map(context) do
    case provider.resolve_scopes(context) do
      {:ok, granted_scopes} -> authorize(skill, granted_scopes)
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # authorized?/2 — boolean convenience
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` when `authorize(skill, granted_scopes)` would return `{:ok, _}`.

  Convenience wrapper for use in boolean contexts (guards, filters, pipeline conditions).
  """
  @spec authorized?(Skill.t(), [String.t()]) :: boolean()
  def authorized?(%Skill{} = skill, granted_scopes) do
    match?({:ok, _}, authorize(skill, granted_scopes))
  end
end
