defmodule SkillKit.KitTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.Definition
  alias SkillKit.Kit
  alias SkillKit.Skill

  describe "struct" do
    test "creates kit with skills and agents" do
      skill = %Skill{name: "tools:echo", namespace: "tools", description: "Echo"}

      agent = %Definition{
        name: "helper",
        description: "Helps",
        system_prompt: "Help.",
        path: "/tmp",
        workspace: "/tmp"
      }

      kit = %Kit{name: "my-kit", skills: [skill], agents: [agent]}

      assert kit.name == "my-kit"
      assert length(kit.skills) == 1
      assert length(kit.agents) == 1
      assert kit.metadata == %{}
    end

    test "defaults to empty lists and map" do
      kit = %Kit{name: "empty"}
      assert kit.skills == []
      assert kit.agents == []
      assert kit.metadata == %{}
    end
  end
end
