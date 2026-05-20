defmodule PersonaChat.ScopeTest do
  use ExUnit.Case, async: true

  alias PersonaChat.Scope

  describe "build/3" do
    test "defaults to visitor permissions" do
      scope = Scope.build("alice")

      assert scope.user == "alice"
      assert scope.persona == nil
      assert "persona:list" in scope.permissions
      assert "persona:chat" in scope.permissions
      refute "persona:create" in scope.permissions
      refute "persona:delete" in scope.permissions
    end

    test "grants owner permissions when owner: true" do
      scope = Scope.build("alice", nil, owner: true)

      assert "persona:create" in scope.permissions
      assert "persona:delete" in scope.permissions
      assert "persona:list" in scope.permissions
      assert "persona:chat" in scope.permissions
    end

    test "stores the persona name when given" do
      scope = Scope.build("alice", "captain_nova")
      assert scope.persona == "captain_nova"
    end
  end

  describe "SkillKit.Scope protocol" do
    test "permissions/1 returns the scope's permission list" do
      scope = Scope.build("alice", nil, owner: true)
      assert SkillKit.Scope.permissions(scope) == scope.permissions
    end

    test "resolve/3 returns the username for $USERNAME" do
      scope = Scope.build("alice")
      assert SkillKit.Scope.resolve(scope, "USERNAME", %{}) == {:ok, "alice"}
    end

    test "resolve/3 returns the persona for $PERSONA when set" do
      scope = Scope.build("alice", "captain_nova")
      assert SkillKit.Scope.resolve(scope, "PERSONA", %{}) == {:ok, "captain_nova"}
    end

    test "resolve/3 returns :error for $PERSONA when not set" do
      scope = Scope.build("alice")
      assert SkillKit.Scope.resolve(scope, "PERSONA", %{}) == :error
    end

    test "resolve/3 returns :error for unknown variables" do
      scope = Scope.build("alice")
      assert SkillKit.Scope.resolve(scope, "UNKNOWN", %{}) == :error
    end
  end
end
