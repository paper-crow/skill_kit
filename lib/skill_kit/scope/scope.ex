defprotocol SkillKit.Scope do
  @moduledoc """
  Protocol for structured scope resolution in SkillKit.

  Scopes carry authorization permissions and resolve named variables
  for skill template substitution and handler context injection.

  ## Implementation

  Define a struct and implement the protocol:

      defmodule MyApp.Scope do
        defstruct [:user, permissions: []]
      end

      defimpl SkillKit.Scope, for: MyApp.Scope do
        def permissions(scope), do: scope.permissions

        def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
        def resolve(_scope, _key, _context), do: :error
      end

  Pass the scope at agent start:

      SkillKit.start_agent(definition, scope: %MyApp.Scope{user: "alice"})
  """

  @type resolve_context :: %{agent: String.t(), skill: String.t()}

  @doc "Returns the list of permission strings for authorization checks."
  @spec permissions(t()) :: [String.t()]
  def permissions(scope)

  @doc """
  Resolves a named variable from the scope.

  Context provides the agent name and skill name so resolution
  can vary based on who is asking.

  Returns `{:ok, value}` or `:error` if the variable is not known.
  """
  @spec resolve(t(), String.t(), resolve_context()) :: {:ok, String.t()} | :error
  def resolve(scope, variable_name, context)
end
