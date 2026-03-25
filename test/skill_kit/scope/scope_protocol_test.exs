defmodule SkillKit.Scope.ProtocolTest do
  use ExUnit.Case, async: true

  alias SkillKit.Scope

  defmodule TestScope do
    defstruct [:user, permissions: []]
  end

  defimpl Scope, for: TestScope do
    def permissions(scope), do: scope.permissions
    def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
    def resolve(_scope, "AGENT_AWARE", %{agent: agent}), do: {:ok, agent}
    def resolve(_scope, "SKILL_AWARE", %{skill: skill}), do: {:ok, skill}
    def resolve(_scope, _key, _context), do: :error
  end

  describe "permissions/1" do
    test "returns permission list from scope" do
      scope = %TestScope{permissions: ["admin:read", "admin:write"]}
      assert Scope.permissions(scope) == ["admin:read", "admin:write"]
    end

    test "returns empty list when no permissions" do
      scope = %TestScope{}
      assert Scope.permissions(scope) == []
    end
  end

  describe "resolve/3" do
    test "resolves known variable" do
      scope = %TestScope{user: "alice"}
      context = %{agent: "test_agent", skill: "test:skill"}
      assert {:ok, "alice"} = Scope.resolve(scope, "USERNAME", context)
    end

    test "returns :error for unknown variable" do
      scope = %TestScope{user: "alice"}
      context = %{agent: "test_agent", skill: "test:skill"}
      assert :error = Scope.resolve(scope, "UNKNOWN", context)
    end

    test "resolve receives agent name in context" do
      scope = %TestScope{}
      context = %{agent: "my_agent", skill: "test:skill"}
      assert {:ok, "my_agent"} = Scope.resolve(scope, "AGENT_AWARE", context)
    end

    test "resolve receives skill name in context" do
      scope = %TestScope{}
      context = %{agent: "test_agent", skill: "memory_kit:user_memory"}
      assert {:ok, "memory_kit:user_memory"} = Scope.resolve(scope, "SKILL_AWARE", context)
    end
  end

  describe "List implementation (backwards compatibility)" do
    test "permissions returns the list as-is" do
      assert Scope.permissions(["admin:read", "admin:write"]) == ["admin:read", "admin:write"]
    end

    test "resolve always returns :error" do
      assert :error = Scope.resolve(["admin:read"], "USERNAME", %{agent: "a", skill: "s"})
    end
  end
end
