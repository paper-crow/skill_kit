defmodule SkillKit.AgentRefTest do
  use ExUnit.Case, async: true

  alias SkillKit.AgentRef

  describe "origin/2" do
    test "classifies the root agent" do
      assert AgentRef.origin("neve", "neve") == :root
    end

    test "classifies skill, delivery, and other sub-loops by prefix" do
      assert AgentRef.origin("neve/skill:plan", "neve") == :skill
      assert AgentRef.origin("neve/delivery:abc", "neve") == :delivery
      assert AgentRef.origin("neve/child", "neve") == :subloop
    end

    test "classifies unrelated agents as :other" do
      assert AgentRef.origin("other", "neve") == :other
    end

    test "does not confuse a longer root-prefixed name for a sub-loop" do
      assert AgentRef.origin("nevex", "neve") == :other
    end
  end
end
