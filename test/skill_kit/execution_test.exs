defmodule SkillKit.ExecutionTest do
  use ExUnit.Case, async: true

  alias SkillKit.{Execution, Hook, Skill}

  defp skill(opts \\ []) do
    %Skill{
      name: Keyword.get(opts, :name, "test:skill"),
      namespace: "test",
      description: "Test skill",
      body: "Do something",
      executor: Keyword.get(opts, :executor, SkillKit.Executor.Shell),
      hooks: Keyword.get(opts, :hooks, [])
    }
  end

  describe "new/4" do
    test "builds an execution with execute step when no hooks" do
      s = skill()
      exec = Execution.new(s, %{"command" => "echo hello"}, %{})

      assert exec.status == :pending
      assert length(exec.steps) == 1
      assert exec.results == %{}
      assert is_nil(exec.suspended_at)
    end

    test "builds pipeline with pre and post hooks filtered by executor name" do
      pre = %Hook{phase: :pre, matcher: ~r/Shell/, handler: fn _ctx -> :allow end}
      post = %Hook{phase: :post, matcher: ~r/Shell/, handler: fn ctx -> ctx.result end}
      non_matching = %Hook{phase: :pre, matcher: ~r/Docker/, handler: fn _ctx -> :allow end}

      s = skill()
      exec = Execution.new(s, %{"command" => "echo hello"}, %{}, all_hooks: [pre, post, non_matching])

      # Should have pre + execute + post = 3 steps (non_matching filtered out)
      assert length(exec.steps) == 3
    end
  end

  describe "run/1" do
    test "executes simple command through Shell and completes" do
      s = skill()
      exec = Execution.new(s, %{"command" => "echo hello"}, %{})

      assert {:ok, %Execution{status: :complete} = result} = Execution.run(exec)
      assert result.results["execute"] == {:ok, "hello\n"}
    end

    test "pre-hook :deny stops execution" do
      deny_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:deny, "blocked"} end
      }

      s = skill()
      exec = Execution.new(s, %{"command" => "echo hello"}, %{}, all_hooks: [deny_hook])

      assert {:error, %Execution{status: :failed} = result} = Execution.run(exec)
      assert result.results["pre:0"] == {:deny, "blocked"}
    end

    test "pre-hook {:allow, input} modifies input" do
      modify_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:allow, %{"command" => "echo modified"}} end
      }

      s = skill()
      exec = Execution.new(s, %{"command" => "echo original"}, %{}, all_hooks: [modify_hook])

      assert {:ok, %Execution{status: :complete} = result} = Execution.run(exec)
      assert result.results["execute"] == {:ok, "modified\n"}
    end

    test "post-hook transforms result" do
      post_hook = %Hook{
        phase: :post,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:ok, "sanitized"} end
      }

      s = skill()
      exec = Execution.new(s, %{"command" => "echo secret"}, %{}, all_hooks: [post_hook])

      assert {:ok, %Execution{status: :complete} = result} = Execution.run(exec)
      assert result.results["post:0"] == {:ok, "sanitized"}
    end

    test "post-hook {:error, reason} causes failed status" do
      post_hook = %Hook{
        phase: :post,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:error, "sensitive data detected"} end
      }

      s = skill()
      exec = Execution.new(s, %{"command" => "echo secret"}, %{}, all_hooks: [post_hook])

      assert {:error, %Execution{status: :failed}} = Execution.run(exec)
    end

    test "executor {:pending, state} suspends execution" do
      s = skill(executor: SkillKit.ExecutionTest.PendingExecutor)
      exec = Execution.new(s, %{"command" => "needs approval"}, %{})

      assert {:pending, %Execution{status: :suspended} = result} = Execution.run(exec)
      assert result.suspended_at == "execute"
    end

    test "pre-hook {:pending, state} suspends execution" do
      pending_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:pending, %{needs: :human_approval}} end
      }

      s = skill()
      exec = Execution.new(s, %{"command" => "echo hello"}, %{}, all_hooks: [pending_hook])

      assert {:pending, %Execution{status: :suspended} = result} = Execution.run(exec)
      assert result.suspended_at == "pre:0"
    end

    test "MFA handler tuple is invoked correctly" do
      mfa_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: {SkillKit.ExecutionTest.MFAHandler, :allow_all, []}
      }

      s = skill()
      exec = Execution.new(s, %{"command" => "echo mfa"}, %{}, all_hooks: [mfa_hook])

      assert {:ok, %Execution{status: :complete}} = Execution.run(exec)
    end

    test "multiple pre-hooks chain — each gets potentially modified input" do
      hook1 = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:allow, %{"command" => "echo step1"}} end
      }

      hook2 = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn ctx ->
          # Should receive the modified input from hook1
          if ctx.input == %{"command" => "echo step1"}, do: :allow, else: {:deny, "wrong input"}
        end
      }

      s = skill()
      exec = Execution.new(s, %{"command" => "echo original"}, %{}, all_hooks: [hook1, hook2])

      assert {:ok, %Execution{status: :complete} = result} = Execution.run(exec)
      assert result.results["execute"] == {:ok, "step1\n"}
    end
  end

  describe "resume/2" do
    test "resumes suspended executor and completes" do
      s = skill(executor: SkillKit.ExecutionTest.PendingExecutor)
      exec = Execution.new(s, %{"command" => "needs approval"}, %{})

      {:pending, suspended} = Execution.run(exec)

      assert {:ok, %Execution{status: :complete} = result} =
               Execution.resume(suspended, :approved)

      assert result.results["execute"] == {:ok, "approved result"}
    end

    test "resumes denied executor and fails" do
      s = skill(executor: SkillKit.ExecutionTest.PendingExecutor)
      exec = Execution.new(s, %{"command" => "needs approval"}, %{})

      {:pending, suspended} = Execution.run(exec)

      assert {:error, %Execution{status: :failed}} =
               Execution.resume(suspended, {:denied, "nope"})
    end
  end

  # Test helper modules

  defmodule PendingExecutor do
    @behaviour SkillKit.Executor.Behaviour

    @impl true
    def execute(%SkillKit.Execution{}), do: {:pending, %{awaiting: :approval}}

    @impl true
    def resume(%SkillKit.Execution{}, _state, :approved), do: {:ok, "approved result"}
    def resume(%SkillKit.Execution{}, _state, {:denied, reason}), do: {:error, {:denied, reason}}
  end

  defmodule MFAHandler do
    def allow_all(_ctx), do: :allow
  end
end
