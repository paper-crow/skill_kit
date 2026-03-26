defmodule SkillKit.Tools.ShellTest do
  use ExUnit.Case, async: true

  alias SkillKit.ToolExecution
  alias SkillKit.Tools.Shell

  describe "execute/1" do
    test "returns {:ok, stdout} for a simple echo command" do
      assert {:ok, "hello\n"} =
               Shell.execute(%ToolExecution{input: %{"command" => "echo hello"}, context: %{}})
    end

    test "returns {:error, {output, exit_code}} for failing command" do
      assert {:error, {_output, exit_code}} =
               Shell.execute(%ToolExecution{input: %{"command" => "exit 1"}, context: %{}})

      assert exit_code != 0
    end

    test "returns {:ok, output} for multi-word command" do
      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo hello world"},
                 context: %{}
               })

      assert String.trim(output) == "hello world"
    end

    test "merges stderr into stdout" do
      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo out && echo err >&2"},
                 context: %{}
               })

      assert String.contains?(output, "out")
      assert String.contains?(output, "err")
    end
  end

  describe "execute/1 with context options" do
    test "runs command in specified working directory" do
      tmp = System.tmp_dir!() |> String.trim_trailing("/")
      # Resolve any symlinks (e.g. macOS /var -> /private/var) so comparison works
      {resolved_tmp, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved_tmp)

      assert {:ok, output} =
               Shell.execute(%ToolExecution{input: %{"command" => "pwd"}, context: %{cwd: tmp}})

      assert String.trim(output) == resolved_tmp
    end

    test "inherits BEAM cwd when :cwd not in context" do
      assert {:ok, output} =
               Shell.execute(%ToolExecution{input: %{"command" => "pwd"}, context: %{}})

      # Should succeed — just proves it doesn't crash without :cwd
      assert is_binary(output)
    end

    test "passes environment variables to the command" do
      context = %{env: [{"SKILL_KIT_TEST_VAR", "hello_from_skill"}]}

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo $SKILL_KIT_TEST_VAR"},
                 context: context
               })

      assert String.trim(output) == "hello_from_skill"
    end

    test "preserves existing environment when adding vars" do
      context = %{env: [{"SKILL_KIT_EXTRA", "extra"}]}

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo $HOME"},
                 context: context
               })

      # HOME should still be set — env merges, not replaces
      assert String.trim(output) == System.get_env("HOME")
    end

    test "supports cwd and env together" do
      tmp = System.tmp_dir!()
      # Resolve any symlinks (e.g. macOS /var -> /private/var) so comparison works
      {resolved, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved)

      context = %{
        cwd: tmp,
        env: [{"SKILL_KIT_COMBO", "works"}]
      }

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo $SKILL_KIT_COMBO from $(pwd)"},
                 context: context
               })

      assert String.trim(output) == "works from #{resolved_tmp}"
    end
  end

  describe "load_kits/1 (Backend)" do
    test "returns a kit named shell" do
      assert {:ok, [kit]} = Shell.load_kits([])
      assert kit.name == "shell"
    end

    test "stores cwd in metadata when provided" do
      assert {:ok, [kit]} = Shell.load_kits(cwd: "/tmp")
      assert kit.metadata.cwd == "/tmp"
    end

    test "stores env in metadata when provided" do
      assert {:ok, [kit]} = Shell.load_kits(env: [{"FOO", "bar"}])
      assert kit.metadata.env == [{"FOO", "bar"}]
    end
  end

  describe "resume/3" do
    test "delegates to execute/1 on approval" do
      exec = %ToolExecution{input: %{"command" => "echo resumed"}, context: %{}}
      assert {:ok, "resumed\n"} = Shell.resume(exec, %{}, :approved)
    end

    test "returns denial error on {:denied, reason}" do
      exec = %ToolExecution{input: %{"command" => "echo nope"}, context: %{}}

      assert {:error, {:denied, "not allowed"}} =
               Shell.resume(exec, %{}, {:denied, "not allowed"})
    end

    test "resume with :approved respects cwd in context" do
      tmp = System.tmp_dir!()
      # Resolve symlinks for macOS
      {resolved, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved)
      exec = %ToolExecution{input: %{"command" => "pwd"}, context: %{cwd: tmp}}
      assert {:ok, output} = Shell.resume(exec, %{}, :approved)
      assert String.trim(output) == resolved_tmp
    end
  end
end
