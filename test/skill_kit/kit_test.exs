defmodule SkillKit.KitTest.TestKit do
  use SkillKit.Kit,
    skills_dir: Path.join(__DIR__, "../support/fixtures/test_kit/skills")

  alias SkillKit.Pipeline

  @impl SkillKit.Handler.Behaviour
  def execute(%Pipeline{skill: %{name: "test_kit:greet"}, input: input}) do
    {:ok, "Hello, #{input["name"]}!"}
  end
end

defmodule SkillKit.KitTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.Definition
  alias SkillKit.Kit
  alias SkillKit.KitTest.TestKit
  alias SkillKit.Pipeline
  alias SkillKit.Skill

  describe "use SkillKit.Kit" do
    test "load_kits/1 returns kit with skills from skills/ directory" do
      assert {:ok, [kit]} = TestKit.load_kits([])
      assert kit.name == "test_kit"
      assert length(kit.skills) == 1

      [skill] = kit.skills
      assert skill.name == "test_kit:greet"
      assert skill.description == "Greet a user"
      assert skill.handler == SkillKit.KitTest.TestKit
      assert skill.body =~ "greet"
    end

    test "source config is stored in skill metadata" do
      assert {:ok, [kit]} = TestKit.load_kits(foo: :bar)
      [skill] = kit.skills
      assert skill.metadata["source_config"] == [foo: :bar]
    end

    test "execute/1 dispatches to the Kit module" do
      {:ok, [kit]} = TestKit.load_kits([])
      [skill] = kit.skills

      execution = %Pipeline{
        skill: skill,
        input: %{"name" => "World"},
        context: %{}
      }

      assert {:ok, "Hello, World!"} = TestKit.execute(execution)
    end

    test "kit name is inferred from module" do
      {:ok, [kit]} = TestKit.load_kits([])
      assert kit.name == "test_kit"
    end
  end

  describe "struct" do
    test "creates kit with skills and agents" do
      skill = %Skill{name: "tools:echo", namespace: "tools", description: "Echo"}

      agent = %Definition{
        name: "helper",
        description: "Helps",
        system_prompt: "Help.",
        path: "/tmp"
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

    test "root_agent defaults to nil" do
      kit = %Kit{name: "empty"}
      assert kit.root_agent == nil
    end

    test "root_agent can hold a Definition struct" do
      root = %Definition{
        name: "root",
        description: "Root agent",
        system_prompt: "You are the root.",
        path: "/tmp"
      }

      kit = %Kit{name: "my-kit", root_agent: root}
      assert kit.root_agent == root
    end
  end
end
