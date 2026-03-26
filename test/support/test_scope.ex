defmodule SkillKit.TestScope do
  @moduledoc false
  defstruct [:user, permissions: []]
end

defimpl SkillKit.Scope, for: SkillKit.TestScope do
  def permissions(scope), do: scope.permissions
  def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
  def resolve(_scope, _key, _context), do: :error
end
