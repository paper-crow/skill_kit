defmodule SkillKit.Tool.RunnerTest do
  use ExUnit.Case, async: true

  alias SkillKit.Tool.Runner
  alias SkillKit.Hook
  alias SkillKit.Kit.Memory
  alias SkillKit.Skill

  setup do
    {:ok, provider} = Memory.start_link([])
    catalog = start_supervised!({SkillKit.Catalog, providers: [{Memory, provider: provider}]})
    %{catalog: catalog, provider: provider}
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
    test "executes a command and returns {:ok, %Pipeline{}}", %{catalog: catalog} do
      assert {:ok, result} = Runner.run(catalog, skill(), "echo hello", %{})
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

      assert {:error, result} = Runner.run(catalog, skill(), "echo hello", %{})
      assert result.status == :failed
    end

    test "works with no hooks registered", %{catalog: catalog} do
      assert {:ok, result} = Runner.run(catalog, skill(), "echo clean", %{})
      assert result.status == :complete
    end

    test "accepts a pre-formed input map", %{catalog: catalog} do
      assert {:ok, result} = Runner.run(catalog, skill(), %{"command" => "echo hello"}, %{})
      assert result.results["execute"] == {:ok, "hello\n"}
    end

    test "passes context with cwd through to Shell tool", %{catalog: catalog} do
      tmp = System.tmp_dir!()
      # Resolve symlinks for macOS
      {resolved, 0} = System.cmd("sh", ["-c", "cd '#{tmp}' && pwd -P"])
      resolved_tmp = String.trim(resolved)
      context = %{cwd: tmp}
      assert {:ok, result} = Runner.run(catalog, skill(), "pwd", context)
      assert result.results["execute"] == {:ok, resolved_tmp <> "\n"}
    end

    test "passes context with env through to Shell tool", %{catalog: catalog} do
      context = %{env: [{"SKILL_KIT_INT_TEST", "integration"}]}
      assert {:ok, result} = Runner.run(catalog, skill(), "echo $SKILL_KIT_INT_TEST", context)
      assert result.results["execute"] == {:ok, "integration\n"}
    end
  end

  describe "resume/2" do
    test "delegates to Pipeline.resume/2", %{catalog: catalog} do
      pending_skill = %Skill{
        name: "test:pending",
        namespace: "test",
        description: "Pending skill",
        body: "Need approval",
        tool: SkillKit.Tool.RunnerTest.PendingTool
      }

      {:pending, suspended} = Runner.run(catalog, pending_skill, "do thing", %{})
      assert {:ok, result} = Runner.resume(suspended, :approved)
      assert result.status == :complete
    end
  end

  defmodule PendingTool do
    @behaviour SkillKit.Tool
    @impl true
    def execute(%SkillKit.Pipeline{}), do: {:pending, %{awaiting: :approval}}
    @impl true
    def resume(%SkillKit.Pipeline{}, _state, :approved), do: {:ok, "approved"}
    def resume(%SkillKit.Pipeline{}, _state, {:denied, reason}), do: {:error, {:denied, reason}}

    @impl true
    def definition do
      %SkillKit.Tool.Definition{name: "pending", description: "test", input_schema: %{}}
    end
  end
end
