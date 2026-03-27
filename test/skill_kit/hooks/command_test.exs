defmodule SkillKit.Hooks.CommandTest do
  use ExUnit.Case, async: true

  alias SkillKit.Hooks.Command

  describe "execute/2" do
    test "returns :ok on exit code 0" do
      assert :ok = Command.execute(%{"command" => "true"}, %{})
    end

    test "returns {:deny, output} on exit code 2" do
      assert {:deny, _output} = Command.execute(%{"command" => "exit 2"}, %{})
    end

    test "returns :ok on non-zero, non-2 exit codes" do
      assert :ok = Command.execute(%{"command" => "exit 1"}, %{})
    end

    test "passes HOOK_INPUT env var with JSON context" do
      context = %{tool: "Shell", input: %{"command" => "echo hi"}}

      assert :ok =
               Command.execute(
                 %{"command" => "test -n \"$HOOK_INPUT\""},
                 context
               )
    end
  end
end
