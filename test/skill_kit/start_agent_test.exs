defmodule SkillKit.StartAgentTest do
  use ExUnit.Case, async: false

  alias SkillKit.Agent.Definition
  alias SkillKit.Kit.Local
  alias SkillKit.Storage

  @fixtures_disk Path.expand("../support/fixtures/skills/with_root_agent", __DIR__)
  @fixtures_path Path.join([__DIR__, "..", "support", "fixtures", "skills", "with_root_agent"])

  setup do
    start_supervised!(Storage.Memory)
    seed_fixture_tree(@fixtures_disk, @fixtures_path)
    :ok
  end

  describe "start_agent/2 with kit provider" do
    test "starts agent from kit provider tuple" do
      assert {:ok, agent} =
               SkillKit.start_agent({Local, dir: @fixtures_path}, caller: self())

      assert agent.name == "root-agent"
      SkillKit.stop_agent(agent)
    end

    test "accepts :name override" do
      assert {:ok, agent} =
               SkillKit.start_agent(
                 {Local, dir: @fixtures_path},
                 name: "custom-name",
                 caller: self()
               )

      assert agent.name == "custom-name"
      SkillKit.stop_agent(agent)
    end

    test "auto-includes agent kit's skills in tool pool" do
      assert {:ok, agent} =
               SkillKit.start_agent(
                 {Local, dir: @fixtures_path},
                 skills: [{Local, dir: @fixtures_path}],
                 caller: self()
               )

      assert agent.name == "root-agent"
      SkillKit.stop_agent(agent)
    end
  end

  describe "start_agent/2 with %Definition{}" do
    test "accepts a %Definition{} struct" do
      {:ok, definition} =
        Definition.parse(Path.join(@fixtures_path, "AGENT.md"))

      assert {:ok, agent} = SkillKit.start_agent(definition, caller: self())

      assert agent.name == "root-agent"
      SkillKit.stop_agent(agent)
    end

    test "overrides agent name" do
      {:ok, definition} =
        Definition.parse(Path.join(@fixtures_path, "AGENT.md"))

      assert {:ok, agent} =
               SkillKit.start_agent(definition, name: "overridden", caller: self())

      assert agent.name == "overridden"
      SkillKit.stop_agent(agent)
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
