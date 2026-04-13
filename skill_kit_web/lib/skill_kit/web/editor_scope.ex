defmodule SkillKit.Web.EditorScope do
  @moduledoc """
  A scope struct for the SkillKit Web editor agent.

  Implements `SkillKit.Scope` to provide permission checking and variable
  resolution for the editor's agent. Resolves `PROJECT_ROOT` and `DOCS_ROOT`
  template variables used in skill bodies.

  ## Example

      scope = %SkillKit.Web.EditorScope{
        user: "alice",
        project_root: "/my/project",
        docs_root: "/my/project/guides"
      }

      SkillKit.start_agent("agents/editor", scope: scope)
  """

  defstruct [
    :user,
    :caller,
    project_root: nil,
    docs_root: nil,
    permissions: ["docs:*", "build:*"]
  ]

  defimpl SkillKit.Scope do
    def permissions(scope), do: scope.permissions

    def resolve(scope, "PROJECT_ROOT", _context) do
      {:ok, scope.project_root || SkillKitWeb.project_root()}
    end

    def resolve(scope, "DOCS_ROOT", _context) do
      {:ok, scope.docs_root || SkillKitWeb.docs_root()}
    end

    def resolve(_scope, _variable, _context), do: :error
  end
end
