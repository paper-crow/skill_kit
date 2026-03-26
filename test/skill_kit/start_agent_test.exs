defmodule SkillKit.StartAgentTest do
  use ExUnit.Case

  alias SkillKit.Agent.Definition
  alias SkillKit.Kit.Local

  @fixtures_path Path.join([__DIR__, "..", "support", "fixtures", "skills", "with_root_agent"])

  describe "start_agent/1 with agent: option" do
    test "starts agent from kit path" do
      assert {:ok, agent} =
               SkillKit.start_agent(
                 agent: {Local, dir: @fixtures_path},
                 caller: self()
               )

      assert agent.name == "root-agent"
      SkillKit.stop_agent(agent)
    end

    test "accepts :name override" do
      assert {:ok, agent} =
               SkillKit.start_agent(
                 agent: {Local, dir: @fixtures_path},
                 name: "custom-name",
                 caller: self()
               )

      assert agent.name == "custom-name"
      SkillKit.stop_agent(agent)
    end

    test "auto-includes agent kit's skills in tool pool" do
      assert {:ok, agent} =
               SkillKit.start_agent(
                 agent: {Local, dir: @fixtures_path},
                 skills: [{Local, dir: @fixtures_path}],
                 caller: self()
               )

      assert agent.name == "root-agent"
      SkillKit.stop_agent(agent)
    end

    test "accepts a %Definition{} struct as agent:" do
      {:ok, definition} =
        Definition.parse(Path.join(@fixtures_path, "AGENT.md"))

      assert {:ok, agent} =
               SkillKit.start_agent(
                 agent: definition,
                 caller: self()
               )

      assert agent.name == "root-agent"
      SkillKit.stop_agent(agent)
    end
  end

  describe "start_agent/2 with :name option" do
    test "overrides agent name" do
      {:ok, definition} =
        Definition.parse(Path.join(@fixtures_path, "AGENT.md"))

      assert {:ok, agent} =
               SkillKit.start_agent(definition, name: "overridden", caller: self())

      assert agent.name == "overridden"
      SkillKit.stop_agent(agent)
    end
  end
end
