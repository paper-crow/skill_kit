defmodule SkillKit.ToolExecutionTest do
  use ExUnit.Case, async: true

  alias SkillKit.Hook
  alias SkillKit.Kit.Memory
  alias SkillKit.Skill
  alias SkillKit.ToolExecution

  defp skill(opts \\ []) do
    %Skill{
      name: Keyword.get(opts, :name, "test:skill"),
      namespace: "test",
      description: "Test skill",
      body: "Do something",
      tool: Keyword.get(opts, :tool, SkillKit.Tools.Shell),
      hooks: Keyword.get(opts, :hooks, [])
    }
  end

  defp build_execution(skill, input, hooks \\ []) do
    %ToolExecution{
      skill: skill,
      input: input,
      context: %{},
      steps: build_steps(hooks, skill.tool)
    }
  end

  defp build_steps(hooks, tool) do
    pre_steps = hooks |> Enum.filter(&(&1.phase == :pre)) |> index_steps(:pre_hook, "pre")
    post_steps = hooks |> Enum.filter(&(&1.phase == :post)) |> index_steps(:post_hook, "post")

    pre_steps ++ [{:execute, "execute", tool}] ++ post_steps
  end

  defp index_steps(hooks, type, prefix) do
    Enum.with_index(hooks, fn hook, i -> {type, "#{prefix}:#{i}", hook} end)
  end

  describe "struct" do
    test "defaults to pending status with empty steps and results" do
      execution = build_execution(skill(), %{"command" => "echo hello"})

      assert execution.status == :pending
      assert length(execution.steps) == 1
      assert execution.results == %{}
      assert is_nil(execution.suspended_at)
    end

    test "includes pre and post hook steps" do
      pre = %Hook{phase: :pre, matcher: ~r/Shell/, handler: fn _ctx -> :allow end}
      post = %Hook{phase: :post, matcher: ~r/Shell/, handler: fn ctx -> ctx.result end}

      execution = build_execution(skill(), %{"command" => "echo hello"}, [pre, post])

      assert length(execution.steps) == 3
    end
  end

  describe "execute/1" do
    test "executes simple command through Shell and completes" do
      execution = build_execution(skill(), %{"command" => "echo hello"})

      assert {:ok, %ToolExecution{status: :complete} = result} = ToolExecution.execute(execution)
      assert result.results["execute"] == {:ok, "hello\n"}
    end

    test "pre-hook :deny stops execution" do
      deny_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:deny, "blocked"} end
      }

      execution = build_execution(skill(), %{"command" => "echo hello"}, [deny_hook])

      assert {:error, %ToolExecution{status: :failed} = result} = ToolExecution.execute(execution)
      assert result.results["pre:0"] == {:deny, "blocked"}
    end

    test "pre-hook {:allow, input} modifies input" do
      modify_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:allow, %{"command" => "echo modified"}} end
      }

      execution = build_execution(skill(), %{"command" => "echo original"}, [modify_hook])

      assert {:ok, %ToolExecution{status: :complete} = result} = ToolExecution.execute(execution)
      assert result.results["execute"] == {:ok, "modified\n"}
    end

    test "post-hook transforms result" do
      post_hook = %Hook{
        phase: :post,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:ok, "sanitized"} end
      }

      execution = build_execution(skill(), %{"command" => "echo secret"}, [post_hook])

      assert {:ok, %ToolExecution{status: :complete} = result} = ToolExecution.execute(execution)
      assert result.results["post:0"] == {:ok, "sanitized"}
    end

    test "post-hook {:error, reason} causes failed status" do
      post_hook = %Hook{
        phase: :post,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:error, "sensitive data detected"} end
      }

      execution = build_execution(skill(), %{"command" => "echo secret"}, [post_hook])

      assert {:error, %ToolExecution{status: :failed}} = ToolExecution.execute(execution)
    end

    test "tool {:pending, state} suspends execution" do
      execution =
        build_execution(
          skill(tool: SkillKit.ToolExecutionTest.PendingTool),
          %{"command" => "needs approval"}
        )

      assert {:pending, %ToolExecution{status: :suspended} = result} =
               ToolExecution.execute(execution)

      assert result.suspended_at == "execute"
    end

    test "pre-hook {:pending, state} suspends execution" do
      pending_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:pending, %{needs: :human_approval}} end
      }

      execution = build_execution(skill(), %{"command" => "echo hello"}, [pending_hook])

      assert {:pending, %ToolExecution{status: :suspended} = result} =
               ToolExecution.execute(execution)

      assert result.suspended_at == "pre:0"
    end

    test "MFA handler tuple is invoked correctly" do
      mfa_hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: {SkillKit.ToolExecutionTest.MFAHandler, :allow_all, []}
      }

      execution = build_execution(skill(), %{"command" => "echo mfa"}, [mfa_hook])

      assert {:ok, %ToolExecution{status: :complete}} = ToolExecution.execute(execution)
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

      execution = build_execution(skill(), %{"command" => "echo original"}, [hook1, hook2])

      assert {:ok, %ToolExecution{status: :complete} = result} = ToolExecution.execute(execution)
      assert result.results["execute"] == {:ok, "step1\n"}
    end
  end

  describe "resume/2" do
    test "resumes suspended tool and completes" do
      execution =
        build_execution(
          skill(tool: SkillKit.ToolExecutionTest.PendingTool),
          %{"command" => "needs approval"}
        )

      {:pending, suspended} = ToolExecution.execute(execution)

      assert {:ok, %ToolExecution{status: :complete} = result} =
               ToolExecution.resume(suspended, :approved)

      assert result.results["execute"] == {:ok, "approved result"}
    end

    test "resumes denied tool and fails" do
      execution =
        build_execution(
          skill(tool: SkillKit.ToolExecutionTest.PendingTool),
          %{"command" => "needs approval"}
        )

      {:pending, suspended} = ToolExecution.execute(execution)

      assert {:error, %ToolExecution{status: :failed}} =
               ToolExecution.resume(suspended, {:denied, "nope"})
    end
  end

  describe "start/4" do
    setup do
      {:ok, provider} = Memory.start_link([])
      catalog = start_supervised!({SkillKit.Catalog, providers: [{Memory, provider: provider}]})
      %{catalog: catalog, provider: provider}
    end

    test "executes a command and returns {:ok, %ToolExecution{}}", %{catalog: catalog} do
      assert {:ok, result} = ToolExecution.start(catalog, skill(), "echo hello")
      assert result.status == :complete
      assert result.results["execute"] == {:ok, "hello\n"}
    end

    test "collects hooks from all registered skills", %{catalog: catalog, provider: provider} do
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

      Memory.put(provider, hook_skill)

      assert {:error, result} = ToolExecution.start(catalog, skill(), "echo hello")
      assert result.status == :failed
    end

    test "works with no hooks registered", %{catalog: catalog} do
      assert {:ok, result} = ToolExecution.start(catalog, skill(), "echo clean")
      assert result.status == :complete
    end

    test "accepts a pre-formed input map", %{catalog: catalog} do
      assert {:ok, result} =
               ToolExecution.start(catalog, skill(), %{"command" => "echo hello"})

      assert result.results["execute"] == {:ok, "hello\n"}
    end

    test "passes context with cwd through to Shell tool", %{catalog: catalog} do
      tmp = System.tmp_dir!()
      # Resolve symlinks for macOS
      {resolved, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved)
      context = %{cwd: tmp}
      assert {:ok, result} = ToolExecution.start(catalog, skill(), "pwd", context)
      assert result.results["execute"] == {:ok, resolved_tmp <> "\n"}
    end

    test "passes context with env through to Shell tool", %{catalog: catalog} do
      context = %{env: [{"SKILL_KIT_INT_TEST", "integration"}]}

      assert {:ok, result} =
               ToolExecution.start(catalog, skill(), "echo $SKILL_KIT_INT_TEST", context)

      assert result.results["execute"] == {:ok, "integration\n"}
    end

    test "resume delegates correctly", %{catalog: catalog} do
      pending_skill = %Skill{
        name: "test:pending",
        namespace: "test",
        description: "Pending skill",
        body: "Need approval",
        tool: SkillKit.ToolExecutionTest.PendingTool
      }

      {:pending, suspended} = ToolExecution.start(catalog, pending_skill, "do thing", %{})
      assert {:ok, result} = ToolExecution.resume(suspended, :approved)
      assert result.status == :complete
    end
  end

  # Test helper modules

  defmodule PendingTool do
    @behaviour SkillKit.Tool

    @impl true
    def execute(%SkillKit.ToolExecution{}), do: {:pending, %{awaiting: :approval}}

    @impl true
    def resume(%SkillKit.ToolExecution{}, _state, :approved), do: {:ok, "approved result"}

    def resume(%SkillKit.ToolExecution{}, _state, {:denied, reason}),
      do: {:error, {:denied, reason}}

    @impl true
    def definition do
      %SkillKit.Tool{name: "pending", description: "test", input_schema: %{}}
    end
  end

  defmodule MFAHandler do
    def allow_all(_ctx), do: :allow
  end
end
