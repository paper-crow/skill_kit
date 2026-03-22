defmodule SkillKit.Executor.ShellTest do
  use ExUnit.Case, async: true

  alias SkillKit.Executor.Shell

  describe "execute/2" do
    test "returns {:ok, stdout} for a simple echo command" do
      assert {:ok, "hello\n"} = Shell.execute("echo hello", %{})
    end

    test "returns {:error, {output, exit_code}} for failing command" do
      assert {:error, {_output, exit_code}} = Shell.execute("exit 1", %{})
      assert exit_code != 0
    end

    test "returns {:ok, output} for multi-word command" do
      assert {:ok, output} = Shell.execute("echo hello world", %{})
      assert String.trim(output) == "hello world"
    end
  end

  describe "resume/3" do
    test "delegates to execute on approval — runs the command from state" do
      state = %{command: "echo resumed"}
      assert {:ok, "resumed\n"} = Shell.resume(state, :approved, %{})
    end

    test "returns denial error on {:denied, reason}" do
      state = %{command: "echo nope"}

      assert {:error, {:denied, "not allowed"}} =
               Shell.resume(state, {:denied, "not allowed"}, %{})
    end
  end
end
