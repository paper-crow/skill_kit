defmodule SkillKit.Tools.ShellTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Storage
  alias SkillKit.ToolExecution
  alias SkillKit.Tools.Shell

  setup :verify_on_exit!

  setup do
    stub(SkillKit.CredentialProvider.Mock, :list, fn _, _ -> [] end)
    stub(SkillKit.CredentialProvider.Mock, :fetch, fn _, _, _ -> {:ok, nil} end)
    start_supervised!(Storage.Memory)
    :ok
  end

  defp test_agent do
    %SkillKit.Agent{name: "test", description: "t", system_prompt: "s"}
  end

  describe "execute/1" do
    test "returns {:ok, stdout} for a simple echo command" do
      assert {:ok, "hello\n"} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo hello"},
                 context: %{agent: test_agent()}
               })
    end

    test "returns {:error, {output, exit_code}} for failing command" do
      assert {:error, {_output, exit_code}} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "exit 1"},
                 context: %{agent: test_agent()}
               })

      assert exit_code != 0
    end

    test "returns {:ok, output} for multi-word command" do
      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo hello world"},
                 context: %{agent: test_agent()}
               })

      assert String.trim(output) == "hello world"
    end

    test "merges stderr into stdout" do
      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo out && echo err >&2"},
                 context: %{agent: test_agent()}
               })

      assert String.contains?(output, "out")
      assert String.contains?(output, "err")
    end
  end

  describe "execute/1 with context options" do
    test "runs command in specified working directory" do
      tmp = System.tmp_dir!() |> String.trim_trailing("/")
      {resolved_tmp, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved_tmp)

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "pwd"},
                 context: %{cwd: tmp, agent: test_agent()}
               })

      assert String.trim(output) == resolved_tmp
    end

    test "inherits BEAM cwd when :cwd not in context" do
      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "pwd"},
                 context: %{agent: test_agent()}
               })

      assert is_binary(output)
    end

    test "child env does NOT inherit arbitrary BEAM env vars" do
      System.put_env("SKILL_KIT_LEAK_TEST", "should_not_appear")

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo ${SKILL_KIT_LEAK_TEST:-absent}"},
                 context: %{agent: test_agent()}
               })

      assert String.trim(output) == "absent"
    after
      System.delete_env("SKILL_KIT_LEAK_TEST")
    end

    test "child env includes hardcoded PATH" do
      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo $PATH"},
                 context: %{agent: test_agent()}
               })

      assert String.trim(output) == "/usr/bin:/bin"
    end

    test "child env includes HOME copied from parent" do
      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo $HOME"},
                 context: %{agent: test_agent()}
               })

      assert String.trim(output) == (System.get_env("HOME") || "")
    end

    test "tool-config :env map is injected into the child env" do
      context = %{
        env: %{"LANG" => "en_US.UTF-8", "PROJECT_DIR" => "/tmp/work"},
        agent: test_agent()
      }

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo $LANG $PROJECT_DIR"},
                 context: context
               })

      assert String.trim(output) == "en_US.UTF-8 /tmp/work"
    end

    test "supports cwd and env together" do
      tmp = System.tmp_dir!()
      {resolved, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved)

      context = %{
        cwd: tmp,
        env: %{"SKILL_KIT_COMBO" => "works"},
        agent: test_agent()
      }

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo $SKILL_KIT_COMBO from $(pwd)"},
                 context: context
               })

      assert String.trim(output) == "works from #{resolved_tmp}"
    end
  end

  describe "execute/1 with CredentialProvider integration" do
    test "injects credentials returned by the provider" do
      agent = test_agent()

      expect(SkillKit.CredentialProvider.Mock, :list, fn SkillKit.Tools.Shell, ^agent ->
        ["GITHUB_TOKEN"]
      end)

      expect(SkillKit.CredentialProvider.Mock, :fetch, fn
        SkillKit.Tools.Shell, ^agent, "GITHUB_TOKEN" -> {:ok, "ghp_secret"}
      end)

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo $GITHUB_TOKEN"},
                 context: %{agent: agent}
               })

      assert String.trim(output) == "ghp_secret"
    end

    test "{:ok, nil} from provider drops the key from env" do
      agent = test_agent()

      expect(SkillKit.CredentialProvider.Mock, :list, fn _, _ -> ["MISSING_KEY"] end)
      expect(SkillKit.CredentialProvider.Mock, :fetch, fn _, _, "MISSING_KEY" -> {:ok, nil} end)

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo ${MISSING_KEY:-absent}"},
                 context: %{agent: agent}
               })

      assert String.trim(output) == "absent"
    end

    test ":error from provider drops the key from env" do
      agent = test_agent()

      expect(SkillKit.CredentialProvider.Mock, :list, fn _, _ -> ["BROKEN_KEY"] end)
      expect(SkillKit.CredentialProvider.Mock, :fetch, fn _, _, "BROKEN_KEY" -> :error end)

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo ${BROKEN_KEY:-absent}"},
                 context: %{agent: agent}
               })

      assert String.trim(output) == "absent"
    end

    test "credentials take precedence over tool-config env on key collision" do
      agent = test_agent()

      expect(SkillKit.CredentialProvider.Mock, :list, fn _, _ -> ["GITHUB_TOKEN"] end)

      expect(SkillKit.CredentialProvider.Mock, :fetch, fn _, _, "GITHUB_TOKEN" ->
        {:ok, "from_provider"}
      end)

      context = %{
        env: %{"GITHUB_TOKEN" => "from_config"},
        agent: agent
      }

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo $GITHUB_TOKEN"},
                 context: context
               })

      assert String.trim(output) == "from_provider"
    end

    test "null default provider injects nothing" do
      original = Application.get_env(:skill_kit, :credential_provider)
      Application.put_env(:skill_kit, :credential_provider, SkillKit.CredentialProvider)

      on_exit(fn -> Application.put_env(:skill_kit, :credential_provider, original) end)

      assert {:ok, output} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "echo ${GITHUB_TOKEN:-absent}"},
                 context: %{agent: test_agent()}
               })

      assert String.trim(output) == "absent"
    end

    test "provider is not called when list/2 returns []" do
      agent = test_agent()

      expect(SkillKit.CredentialProvider.Mock, :list, fn _, _ -> [] end)
      # No expect/stub for :fetch — if Shell calls it, Mox fails the test.

      assert {:ok, _} =
               Shell.execute(%ToolExecution{
                 input: %{"command" => "true"},
                 context: %{agent: agent}
               })
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
      assert {:ok, [kit]} = Shell.load_kits(env: %{"FOO" => "bar"})
      assert kit.metadata.env == %{"FOO" => "bar"}
    end
  end

  describe "resume/3" do
    test "delegates to execute/1 on approval" do
      exec = %ToolExecution{
        input: %{"command" => "echo resumed"},
        context: %{agent: test_agent()}
      }

      assert {:ok, "resumed\n"} = Shell.resume(exec, %{}, :approved)
    end

    test "returns denial error on {:denied, reason}" do
      exec = %ToolExecution{
        input: %{"command" => "echo nope"},
        context: %{agent: test_agent()}
      }

      assert {:error, {:denied, "not allowed"}} =
               Shell.resume(exec, %{}, {:denied, "not allowed"})
    end

    test "resume with :approved respects cwd in context" do
      tmp = System.tmp_dir!()
      {resolved, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved)

      exec = %ToolExecution{
        input: %{"command" => "pwd"},
        context: %{cwd: tmp, agent: test_agent()}
      }

      assert {:ok, output} = Shell.resume(exec, %{}, :approved)
      assert String.trim(output) == resolved_tmp
    end
  end
end
