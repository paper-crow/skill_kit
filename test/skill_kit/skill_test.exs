defmodule SkillKit.SkillTest do
  use ExUnit.Case, async: true

  alias SkillKit.Skill

  describe "Skill struct" do
    test "has expected fields" do
      skill = %Skill{}
      assert Map.has_key?(skill, :name)
      assert Map.has_key?(skill, :namespace)
      assert Map.has_key?(skill, :description)
      assert Map.has_key?(skill, :body)
      assert Map.has_key?(skill, :location)
      assert Map.has_key?(skill, :required_scope)
      assert Map.has_key?(skill, :executor)
      assert Map.has_key?(skill, :hooks)
    end

    test "does not have removed fields" do
      skill = %Skill{}
      refute Map.has_key?(skill, :type)
      refute Map.has_key?(skill, :module)
      refute Map.has_key?(skill, :source)
    end

    test "required_scope defaults to empty list" do
      assert %Skill{}.required_scope == []
    end

    test "executor defaults to SkillKit.Executor.Shell" do
      assert %Skill{}.executor == SkillKit.Executor.Shell
    end

    test "hooks defaults to empty list" do
      assert %Skill{}.hooks == []
    end

    test "nil-defaulting fields default to nil" do
      skill = %Skill{}
      assert is_nil(skill.name)
      assert is_nil(skill.namespace)
      assert is_nil(skill.description)
      assert is_nil(skill.body)
      assert is_nil(skill.location)
    end
  end
end
