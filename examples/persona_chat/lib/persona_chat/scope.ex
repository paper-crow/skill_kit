defmodule PersonaChat.Scope do
  @moduledoc """
  Scope for the PersonaChat example app.

  Carries user identity, persona context, and permissions.
  Implements SkillKit.Scope protocol for variable resolution.
  """

  @enforce_keys [:user]
  defstruct [:user, :persona, permissions: []]

  @type t :: %__MODULE__{
          user: String.t(),
          persona: String.t() | nil,
          permissions: [String.t()]
        }

  @owner_permissions ["persona:create", "persona:delete", "persona:list", "persona:chat"]
  @visitor_permissions ["persona:list", "persona:chat"]

  @doc "Builds a scope for the given user, detecting owner status."
  @spec build(String.t(), String.t() | nil, keyword()) :: t()
  def build(username, persona \\ nil, opts \\ []) do
    owner = Keyword.get(opts, :owner, false)

    %__MODULE__{
      user: username,
      persona: persona,
      permissions: if(owner, do: @owner_permissions, else: @visitor_permissions)
    }
  end
end

defimpl SkillKit.Scope, for: PersonaChat.Scope do
  def permissions(scope), do: scope.permissions

  def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
  def resolve(scope, "PERSONA", _context) when not is_nil(scope.persona), do: {:ok, scope.persona}
  def resolve(_scope, _key, _context), do: :error
end
