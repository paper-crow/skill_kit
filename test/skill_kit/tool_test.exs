defmodule SkillKit.ToolTest do
  use ExUnit.Case, async: true

  alias SkillKit.Tool
  alias SkillKit.Tools.Shell

  describe "Tool struct" do
    test "creates with required fields" do
      td = %Tool{name: "bash", description: "Run a command", input_schema: %{}}
      assert td.name == "bash"
    end
  end

  describe "Shell.definition/0" do
    test "returns a valid Tool" do
      td = Shell.definition()
      assert %Tool{} = td
      assert td.name == "bash"
      assert is_binary(td.description)
      assert td.input_schema["properties"]["command"]
    end
  end
end
