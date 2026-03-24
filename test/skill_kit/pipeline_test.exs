defmodule SkillKit.PipelineTest do
  use ExUnit.Case, async: true

  alias SkillKit.Hook
  alias SkillKit.Pipeline
  alias SkillKit.Skill

  defp skill(opts \\ []) do
    %Skill{
      name: Keyword.get(opts, :name, "test:skill"),
      namespace: "test",
      description: "Test skill",
      body: "Do something",
      handler: Keyword.get(opts, :handler, SkillKit.Handler.Shell),
      hooks: Keyword.get(opts, :hooks, [])
    }
  end

  describe "new/4" do
    test "builds a pipeline with execute step when no hooks" do
      s = skill()
      exec = Pipeline.new(s, %{"command" => "echo hello"}, %{})

      assert exec.status == :pending
      assert length(exec.steps) == 1
      assert exec.results == %{}
      assert is_nil(exec.suspended_at)
    end

    test "builds pipeline with pre and post hooks" do
      pre = %Hook{phase: :pre, matcher: ~r/Shell/, handler: fn _ctx -> :allow end}
      post = %Hook{phase: :post, matcher: ~r/Shell/, handler: fn ctx -> ctx.result end}

      s = skill()

      exec =
        Pipeline.new(s, %{"command" => "echo hello"}, %{}, hooks: [pre, post])

      # pre + execute + post = 3 steps
      assert length(exec.steps) == 3
    end
  end

  describe "run/1" do
    test "executes simple command through Shell and completes" do
      s = skill()
      exec = Pipeline.new(s, %{"command" => "echo hello"}, %{})

      assert {:ok, %Pipeline{status: :complete} = result} = Pipeline.run(exec)
      assert result.results["execute"] == {:ok, "hello\n"}
    end

    test "pre-hook :deny stops execution" do
      deny_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:deny, "blocked"} end
      }

      s = skill()
      exec = Pipeline.new(s, %{"command" => "echo hello"}, %{}, hooks: [deny_hook])

      assert {:error, %Pipeline{status: :failed} = result} = Pipeline.run(exec)
      assert result.results["pre:0"] == {:deny, "blocked"}
    end

    test "pre-hook {:allow, input} modifies input" do
      modify_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:allow, %{"command" => "echo modified"}} end
      }

      s = skill()
      exec = Pipeline.new(s, %{"command" => "echo original"}, %{}, hooks: [modify_hook])

      assert {:ok, %Pipeline{status: :complete} = result} = Pipeline.run(exec)
      assert result.results["execute"] == {:ok, "modified\n"}
    end

    test "post-hook transforms result" do
      post_hook = %Hook{
        phase: :post,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:ok, "sanitized"} end
      }

      s = skill()
      exec = Pipeline.new(s, %{"command" => "echo secret"}, %{}, hooks: [post_hook])

      assert {:ok, %Pipeline{status: :complete} = result} = Pipeline.run(exec)
      assert result.results["post:0"] == {:ok, "sanitized"}
    end

    test "post-hook {:error, reason} causes failed status" do
      post_hook = %Hook{
        phase: :post,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:error, "sensitive data detected"} end
      }

      s = skill()
      exec = Pipeline.new(s, %{"command" => "echo secret"}, %{}, hooks: [post_hook])

      assert {:error, %Pipeline{status: :failed}} = Pipeline.run(exec)
    end

    test "handler {:pending, state} suspends execution" do
      s = skill(handler: SkillKit.PipelineTest.PendingHandler)
      exec = Pipeline.new(s, %{"command" => "needs approval"}, %{})

      assert {:pending, %Pipeline{status: :suspended} = result} = Pipeline.run(exec)
      assert result.suspended_at == "execute"
    end

    test "pre-hook {:pending, state} suspends execution" do
      pending_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:pending, %{needs: :human_approval}} end
      }

      s = skill()
      exec = Pipeline.new(s, %{"command" => "echo hello"}, %{}, hooks: [pending_hook])

      assert {:pending, %Pipeline{status: :suspended} = result} = Pipeline.run(exec)
      assert result.suspended_at == "pre:0"
    end

    test "MFA handler tuple is invoked correctly" do
      mfa_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: {SkillKit.PipelineTest.MFAHandler, :allow_all, []}
      }

      s = skill()
      exec = Pipeline.new(s, %{"command" => "echo mfa"}, %{}, hooks: [mfa_hook])

      assert {:ok, %Pipeline{status: :complete}} = Pipeline.run(exec)
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
      exec = Pipeline.new(s, %{"command" => "echo original"}, %{}, hooks: [hook1, hook2])

      assert {:ok, %Pipeline{status: :complete} = result} = Pipeline.run(exec)
      assert result.results["execute"] == {:ok, "step1\n"}
    end
  end

  describe "resume/2" do
    test "resumes suspended handler and completes" do
      s = skill(handler: SkillKit.PipelineTest.PendingHandler)
      exec = Pipeline.new(s, %{"command" => "needs approval"}, %{})

      {:pending, suspended} = Pipeline.run(exec)

      assert {:ok, %Pipeline{status: :complete} = result} =
               Pipeline.resume(suspended, :approved)

      assert result.results["execute"] == {:ok, "approved result"}
    end

    test "resumes denied handler and fails" do
      s = skill(handler: SkillKit.PipelineTest.PendingHandler)
      exec = Pipeline.new(s, %{"command" => "needs approval"}, %{})

      {:pending, suspended} = Pipeline.run(exec)

      assert {:error, %Pipeline{status: :failed}} =
               Pipeline.resume(suspended, {:denied, "nope"})
    end
  end

  # Test helper modules

  defmodule PendingHandler do
    @behaviour SkillKit.Handler.Behaviour

    @impl true
    def execute(%SkillKit.Pipeline{}), do: {:pending, %{awaiting: :approval}}

    @impl true
    def resume(%SkillKit.Pipeline{}, _state, :approved), do: {:ok, "approved result"}
    def resume(%SkillKit.Pipeline{}, _state, {:denied, reason}), do: {:error, {:denied, reason}}

    @impl true
    def tool_definition do
      %SkillKit.Handler.ToolDefinition{name: "pending", description: "test", input_schema: %{}}
    end
  end

  defmodule MFAHandler do
    def allow_all(_ctx), do: :allow
  end
end
