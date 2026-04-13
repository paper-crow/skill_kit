defmodule SkillKit.Web.EditorScopeTest do
  use ExUnit.Case, async: true

  alias SkillKit.Web.EditorScope

  test "permissions returns configured permissions" do
    scope = %EditorScope{permissions: ["docs:*", "build:*"]}
    assert SkillKit.Scope.permissions(scope) == ["docs:*", "build:*"]
  end

  test "permissions defaults to all docs and build" do
    scope = %EditorScope{}
    permissions = SkillKit.Scope.permissions(scope)
    assert "docs:*" in permissions
    assert "build:*" in permissions
  end

  test "resolve returns project_root for PROJECT_ROOT" do
    scope = %EditorScope{project_root: "/my/project"}
    context = %{agent: "assistant", skill: "docs:read"}
    assert {:ok, "/my/project"} = SkillKit.Scope.resolve(scope, "PROJECT_ROOT", context)
  end

  test "resolve returns docs_root for DOCS_ROOT" do
    scope = %EditorScope{docs_root: "/my/project/guides"}
    context = %{agent: "assistant", skill: "docs:read"}
    assert {:ok, "/my/project/guides"} = SkillKit.Scope.resolve(scope, "DOCS_ROOT", context)
  end

  test "resolve returns :error for unknown variables" do
    scope = %EditorScope{}
    context = %{agent: "assistant", skill: "docs:read"}
    assert :error = SkillKit.Scope.resolve(scope, "UNKNOWN_VAR", context)
  end
end
