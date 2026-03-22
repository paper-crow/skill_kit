defmodule SkillKit.ExecutorTest do
  use ExUnit.Case, async: true

  alias SkillKit.{Executor, Hook, Skill}

  setup do
    name = :"registry_#{:erlang.unique_integer([:positive])}"
    _pid = start_supervised!({SkillKit.Registry, name: name})
    %{registry: name}
  end

  defp skill do
    %Skill{
      name: "test:run",
      namespace: "test",
      description: "Test runner",
      body: "Run things"
    }
  end

  describe "run/4" do
    test "executes a command and returns {:ok, %Execution{}}", %{registry: registry} do
      assert {:ok, result} = Executor.run(registry, skill(), "echo hello", %{})
      assert result.status == :complete
      assert result.results["execute"] == {:ok, "hello\n"}
    end

    test "collects hooks from all registered skills", %{registry: registry} do
      hook_skill = %Skill{
        name: "hooks:blocker",
        namespace: "hooks",
        description: "Blocks commands",
        body: "I block things",
        hooks: [
          %Hook{
            phase: :pre,
            matcher: ~r/Shell/,
            handler: fn _ctx -> {:deny, "blocked by hook skill"} end
          }
        ]
      }

      SkillKit.Registry.register(registry, hook_skill)

      assert {:error, result} = Executor.run(registry, skill(), "echo hello", %{})
      assert result.status == :failed
    end

    test "works with no hooks registered", %{registry: registry} do
      assert {:ok, result} = Executor.run(registry, skill(), "echo clean", %{})
      assert result.status == :complete
    end

    test "passes context with cwd through to Shell executor", %{registry: registry} do
      tmp = System.tmp_dir!()
      # Resolve symlinks for macOS
      {resolved, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved)
      context = %{cwd: tmp}
      assert {:ok, result} = Executor.run(registry, skill(), "pwd", context)
      assert result.results["execute"] == {:ok, resolved_tmp <> "\n"}
    end

    test "passes context with env through to Shell executor", %{registry: registry} do
      context = %{env: [{"SKILL_KIT_INT_TEST", "integration"}]}
      assert {:ok, result} = Executor.run(registry, skill(), "echo $SKILL_KIT_INT_TEST", context)
      assert result.results["execute"] == {:ok, "integration\n"}
    end
  end

  describe "resume/2" do
    test "delegates to Execution.resume/2", %{registry: registry} do
      pending_skill = %Skill{
        name: "test:pending",
        namespace: "test",
        description: "Pending skill",
        body: "Need approval",
        executor: SkillKit.ExecutorTest.PendingExecutor
      }

      {:pending, suspended} = Executor.run(registry, pending_skill, "do thing", %{})
      assert {:ok, result} = Executor.resume(suspended, :approved)
      assert result.status == :complete
    end
  end

  defmodule PendingExecutor do
    @behaviour SkillKit.Executor.Behaviour
    @impl true
    def execute(_cmd, _ctx), do: {:pending, %{awaiting: :approval}}
    @impl true
    def resume(_state, :approved, _ctx), do: {:ok, "approved"}
    def resume(_state, {:denied, reason}, _ctx), do: {:error, {:denied, reason}}
  end
end
