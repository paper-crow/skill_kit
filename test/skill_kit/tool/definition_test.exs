defmodule SkillKit.Tool.DefinitionTest do
  use ExUnit.Case, async: true

  alias SkillKit.Tool.Definition
  alias SkillKit.Tools.Shell

  describe "ToolDefinition struct" do
    test "creates with required fields" do
      td = %Definition{name: "bash", description: "Run a command", input_schema: %{}}
      assert td.name == "bash"
    end
  end

  describe "Shell.definition/0" do
    test "returns a valid Definition" do
      td = Shell.definition()
      assert %Definition{} = td
      assert td.name == "bash"
      assert is_binary(td.description)
      assert td.input_schema["properties"]["command"]
    end
  end
end
