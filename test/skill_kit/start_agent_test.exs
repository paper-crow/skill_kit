defmodule SkillKit.StartAgentTest do
  use ExUnit.Case

  alias SkillKit.Agent.Definition
  alias SkillKit.Backend.Filesystem

  @fixtures_path Path.join([__DIR__, "..", "support", "fixtures", "skills", "with_root_agent"])
  @no_agent_path Path.join([__DIR__, "..", "support", "fixtures", "skills", "valid"])

  describe "start_agent/1 skill-driven" do
    test "discovers and starts root agent from skills" do
      assert {:ok, agent} =
               SkillKit.start_agent(
                 skills: [{Filesystem, dir: @fixtures_path}],
                 caller: self()
               )

      assert agent.name == "root-agent"
      SkillKit.stop_agent(agent)
    end

    test "accepts :name override" do
      assert {:ok, agent} =
               SkillKit.start_agent(
                 skills: [{Filesystem, dir: @fixtures_path}],
                 name: "custom-name",
                 caller: self()
               )

      assert agent.name == "custom-name"
      SkillKit.stop_agent(agent)
    end

    test "returns error when no root agent found" do
      assert {:error, :no_root_agent} =
               SkillKit.start_agent(
                 skills: [{Filesystem, dir: @no_agent_path}],
                 caller: self()
               )
    end

    test "returns error when multiple root agents found" do
      assert {:error, :multiple_root_agents} =
               SkillKit.start_agent(
                 skills: [
                   {Filesystem, dir: @fixtures_path},
                   {Filesystem, dir: @fixtures_path}
                 ],
                 caller: self()
               )
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
