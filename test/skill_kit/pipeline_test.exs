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
      handler: Keyword.get(opts, :handler, SkillKit.Shell),
      hooks: Keyword.get(opts, :hooks, [])
    }
  end

  defp build_pipeline(skill, input, hooks \\ []) do
    %Pipeline{
      skill: skill,
      input: input,
      context: %{},
      steps: build_steps(hooks, skill.handler)
    }
  end

  defp build_steps(hooks, handler) do
    pre_steps = hooks |> Enum.filter(&(&1.phase == :pre)) |> index_steps(:pre_hook, "pre")
    post_steps = hooks |> Enum.filter(&(&1.phase == :post)) |> index_steps(:post_hook, "post")

    pre_steps ++ [{:execute, "execute", handler}] ++ post_steps
  end

  defp index_steps(hooks, type, prefix) do
    Enum.with_index(hooks, fn hook, i -> {type, "#{prefix}:#{i}", hook} end)
  end

  describe "struct" do
    test "defaults to pending status with empty steps and results" do
      pipeline = build_pipeline(skill(), %{"command" => "echo hello"})

      assert pipeline.status == :pending
      assert length(pipeline.steps) == 1
      assert pipeline.results == %{}
      assert is_nil(pipeline.suspended_at)
    end

    test "includes pre and post hook steps" do
      pre = %Hook{phase: :pre, matcher: ~r/Shell/, handler: fn _ctx -> :allow end}
      post = %Hook{phase: :post, matcher: ~r/Shell/, handler: fn ctx -> ctx.result end}

      pipeline = build_pipeline(skill(), %{"command" => "echo hello"}, [pre, post])

      assert length(pipeline.steps) == 3
    end
  end

  describe "run/1" do
    test "executes simple command through Shell and completes" do
      pipeline = build_pipeline(skill(), %{"command" => "echo hello"})

      assert {:ok, %Pipeline{status: :complete} = result} = Pipeline.run(pipeline)
      assert result.results["execute"] == {:ok, "hello\n"}
    end

    test "pre-hook :deny stops execution" do
      deny_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:deny, "blocked"} end
      }

      pipeline = build_pipeline(skill(), %{"command" => "echo hello"}, [deny_hook])

      assert {:error, %Pipeline{status: :failed} = result} = Pipeline.run(pipeline)
      assert result.results["pre:0"] == {:deny, "blocked"}
    end

    test "pre-hook {:allow, input} modifies input" do
      modify_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:allow, %{"command" => "echo modified"}} end
      }

      pipeline = build_pipeline(skill(), %{"command" => "echo original"}, [modify_hook])

      assert {:ok, %Pipeline{status: :complete} = result} = Pipeline.run(pipeline)
      assert result.results["execute"] == {:ok, "modified\n"}
    end

    test "post-hook transforms result" do
      post_hook = %Hook{
        phase: :post,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:ok, "sanitized"} end
      }

      pipeline = build_pipeline(skill(), %{"command" => "echo secret"}, [post_hook])

      assert {:ok, %Pipeline{status: :complete} = result} = Pipeline.run(pipeline)
      assert result.results["post:0"] == {:ok, "sanitized"}
    end

    test "post-hook {:error, reason} causes failed status" do
      post_hook = %Hook{
        phase: :post,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:error, "sensitive data detected"} end
      }

      pipeline = build_pipeline(skill(), %{"command" => "echo secret"}, [post_hook])

      assert {:error, %Pipeline{status: :failed}} = Pipeline.run(pipeline)
    end

    test "handler {:pending, state} suspends execution" do
      pipeline =
        build_pipeline(
          skill(handler: SkillKit.PipelineTest.PendingHandler),
          %{"command" => "needs approval"}
        )

      assert {:pending, %Pipeline{status: :suspended} = result} = Pipeline.run(pipeline)
      assert result.suspended_at == "execute"
    end

    test "pre-hook {:pending, state} suspends execution" do
      pending_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:pending, %{needs: :human_approval}} end
      }

      pipeline = build_pipeline(skill(), %{"command" => "echo hello"}, [pending_hook])

      assert {:pending, %Pipeline{status: :suspended} = result} = Pipeline.run(pipeline)
      assert result.suspended_at == "pre:0"
    end

    test "MFA handler tuple is invoked correctly" do
      mfa_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: {SkillKit.PipelineTest.MFAHandler, :allow_all, []}
      }

      pipeline = build_pipeline(skill(), %{"command" => "echo mfa"}, [mfa_hook])

      assert {:ok, %Pipeline{status: :complete}} = Pipeline.run(pipeline)
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
          if ctx.input == %{"command" => "echo step1"}, do: :allow, else: {:deny, "wrong input"}
        end
      }

      pipeline = build_pipeline(skill(), %{"command" => "echo original"}, [hook1, hook2])

      assert {:ok, %Pipeline{status: :complete} = result} = Pipeline.run(pipeline)
      assert result.results["execute"] == {:ok, "step1\n"}
    end
  end

  describe "resume/2" do
    test "resumes suspended handler and completes" do
      pipeline =
        build_pipeline(
          skill(handler: SkillKit.PipelineTest.PendingHandler),
          %{"command" => "needs approval"}
        )

      {:pending, suspended} = Pipeline.run(pipeline)

      assert {:ok, %Pipeline{status: :complete} = result} =
               Pipeline.resume(suspended, :approved)

      assert result.results["execute"] == {:ok, "approved result"}
    end

    test "resumes denied handler and fails" do
      pipeline =
        build_pipeline(
          skill(handler: SkillKit.PipelineTest.PendingHandler),
          %{"command" => "needs approval"}
        )

      {:pending, suspended} = Pipeline.run(pipeline)

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
