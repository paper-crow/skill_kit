defmodule SkillKit.Executor.ToolDefinitionTest do
  use ExUnit.Case, async: true

  alias SkillKit.Executor.Shell
  alias SkillKit.Executor.ToolDefinition

  describe "ToolDefinition struct" do
    test "creates with required fields" do
      td = %ToolDefinition{name: "bash", description: "Run a command", input_schema: %{}}
      assert td.name == "bash"
    end
  end

  describe "Shell.tool_definition/0" do
    test "returns a valid ToolDefinition" do
      td = Shell.tool_definition()
      assert %ToolDefinition{} = td
      assert td.name == "bash"
      assert is_binary(td.description)
      assert td.input_schema["properties"]["command"]
    end
  end
end
