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

    test "merges stderr into stdout" do
      assert {:ok, output} = Shell.execute("echo out && echo err >&2", %{})
      assert String.contains?(output, "out")
      assert String.contains?(output, "err")
    end
  end

  describe "execute/2 with context options" do
    test "runs command in specified working directory" do
      tmp = System.tmp_dir!() |> String.trim_trailing("/")
      # Resolve any symlinks (e.g. macOS /var -> /private/var) so comparison works
      {resolved_tmp, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved_tmp)
      context = %{cwd: tmp}
      assert {:ok, output} = Shell.execute("pwd", context)
      assert String.trim(output) == resolved_tmp
    end

    test "inherits BEAM cwd when :cwd not in context" do
      assert {:ok, output} = Shell.execute("pwd", %{})
      # Should succeed — just proves it doesn't crash without :cwd
      assert is_binary(output)
    end

    test "passes environment variables to the command" do
      context = %{env: [{"SKILL_KIT_TEST_VAR", "hello_from_skill"}]}
      assert {:ok, output} = Shell.execute("echo $SKILL_KIT_TEST_VAR", context)
      assert String.trim(output) == "hello_from_skill"
    end

    test "preserves existing environment when adding vars" do
      context = %{env: [{"SKILL_KIT_EXTRA", "extra"}]}
      assert {:ok, output} = Shell.execute("echo $HOME", context)
      # HOME should still be set — env merges, not replaces
      assert String.trim(output) == System.get_env("HOME")
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
