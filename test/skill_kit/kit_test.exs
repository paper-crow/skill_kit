defmodule SkillKit.KitTest.TestKit do
  use SkillKit.Kit, path: Path.expand("../support/fixtures/test_kit", __DIR__)

  alias SkillKit.ToolExecution

  @impl SkillKit.Tool
  def execute(%ToolExecution{skill: %{name: "test_kit:greet"}, input: input}) do
    {:ok, "Hello, #{input["name"]}!"}
  end
end

defmodule SkillKit.KitTest.TestKitWithAgent do
  use SkillKit.Kit, path: Path.expand("../support/fixtures/test_kit_with_agent", __DIR__)

  @impl SkillKit.Tool
  def execute(_execution), do: {:ok, "pong"}
end

defmodule SkillKit.KitTest do
  use ExUnit.Case, async: false

  alias SkillKit.Agent
  alias SkillKit.Kit
  alias SkillKit.KitTest.TestKit
  alias SkillKit.KitTest.TestKitWithAgent
  alias SkillKit.Skill
  alias SkillKit.Storage
  alias SkillKit.ToolExecution

  @fixtures_disk Path.expand("../support/fixtures/test_kit/skills", __DIR__)
  @fixtures_storage Path.join([__DIR__, "../support/fixtures/test_kit/skills"])

  setup do
    start_supervised!(Storage.Memory)
    seed_fixture_tree(@fixtures_disk, @fixtures_storage)
    :ok
  end

  describe "use SkillKit.Kit" do
    test "load_kits/1 returns kit with skills from skills/ directory" do
      assert {:ok, [kit]} = TestKit.load_kits([])
      assert kit.name == "test_kit"
      assert length(kit.skills) == 1

      [skill] = kit.skills
      assert skill.name == "test_kit:greet"
      assert skill.description == "Greet a user"
      assert skill.tool == SkillKit.KitTest.TestKit
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

      execution = %ToolExecution{
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

  describe "compile-time agent loading" do
    test "load_kits includes agent definition when AGENT.md exists" do
      assert {:ok, [kit]} = TestKitWithAgent.load_kits([])
      assert kit.agent != nil
      assert kit.agent.name == "test-agent"
      assert kit.agent.description == "A test agent for kit loading"
      assert kit.agent.system_prompt =~ "You are a test agent."
    end

    test "agent_definition/0 returns the agent" do
      agent = TestKitWithAgent.agent_definition()
      assert agent != nil
      assert agent.name == "test-agent"
    end

    test "agent_definition/0 returns nil when no AGENT.md" do
      assert TestKit.agent_definition() == nil
    end

    test "kit includes both skills and agent" do
      assert {:ok, [kit]} = TestKitWithAgent.load_kits([])
      assert length(kit.skills) == 1
      assert kit.agent != nil
    end
  end

  describe "struct" do
    test "creates kit with skills and agents" do
      skill = %Skill{name: "tools:echo", namespace: "tools", description: "Echo"}

      agent = %Agent{
        name: "helper",
        description: "Helps",
        system_prompt: "Help.",
        path: "/tmp"
      }

      kit = %Kit{name: "my-kit", skills: [skill], subagents: [agent]}

      assert kit.name == "my-kit"
      assert length(kit.skills) == 1
      assert length(kit.subagents) == 1
      assert kit.metadata == %{}
    end

    test "defaults to empty lists and map" do
      kit = %Kit{name: "empty"}
      assert kit.skills == []
      assert kit.subagents == []
      assert kit.metadata == %{}
    end

    test "agent defaults to nil" do
      kit = %Kit{name: "empty"}
      assert kit.agent == nil
    end

    test "agent can hold an Agent struct" do
      root = %Agent{
        name: "root",
        description: "Root agent",
        system_prompt: "You are the root.",
        path: "/tmp"
      }

      kit = %Kit{name: "my-kit", agent: root}
      assert kit.agent == root
    end
  end

  defp seed_fixture_tree(disk_path, storage_path) do
    Storage.ensure_dir!(storage_path)

    case File.ls(disk_path) do
      {:ok, entries} -> Enum.each(entries, &seed_entry(disk_path, storage_path, &1))
      {:error, _} -> :ok
    end
  end

  defp seed_entry(disk_path, storage_path, entry) do
    disk_entry = Path.join(disk_path, entry)
    storage_entry = Path.join(storage_path, entry)

    if File.dir?(disk_entry) do
      seed_fixture_tree(disk_entry, storage_entry)
    else
      {:ok, content} = File.read(disk_entry)
      Storage.put!(storage_entry, content)
    end
  end
end
