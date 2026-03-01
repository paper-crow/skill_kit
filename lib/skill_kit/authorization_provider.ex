defmodule SkillKit.AuthorizationProvider do
  @moduledoc """
  Behaviour contract for scope-resolution providers used by `SkillKit.Authorization.authorize/3`.

  An authorization provider is any module that implements this behaviour. The single
  callback `resolve_scopes/1` receives an opaque context map and returns the list of
  scope strings granted to the caller, or an error.

  ## Implementation Example

      defmodule MyApp.TokenProvider do
        @behaviour SkillKit.AuthorizationProvider

        @impl SkillKit.AuthorizationProvider
        def resolve_scopes(%{token: token}) do
          case MyApp.Tokens.verify(token) do
            {:ok, claims} -> {:ok, claims["scopes"]}
            {:error, reason} -> {:error, reason}
          end
        end
      end

  ## Errors

  Provider errors pass through unchanged to the caller of `authorize/3`.
  For example, `{:error, :token_expired}` returned here arrives as
  `{:error, :token_expired}` at the call site — providers must NOT be
  rescued or normalized inside `SkillKit.Authorization`.

  ## Context Shape

  The `context` argument is fully opaque (`map()`). No required keys are
  enforced by the behaviour contract. Each provider defines its own
  expected shape and pattern-matches accordingly.
  """

  @doc """
  Resolves the scope list for the given context.

  Returns `{:ok, scopes}` on success where `scopes` is a flat list of scope
  strings (e.g. `["admin:read", "tools:*"]`), or `{:error, reason}` on failure.

  The `context` map is opaque — implementations are free to require any
  structure and should return `{:error, reason}` for missing or invalid inputs.
  """
  @callback resolve_scopes(context :: map()) :: {:ok, [String.t()]} | {:error, term()}
end
