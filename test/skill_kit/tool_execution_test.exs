defmodule SkillKit.ToolExecutionTest do
  use ExUnit.Case, async: true

  alias SkillKit.Skill
  alias SkillKit.ToolExecution

  describe "execute/1" do
    test "completes when tool returns {:ok, value}" do
      exec = %ToolExecution{
        tool: SkillKit.Tools.Shell,
        input: %{"command" => "echo hello"},
        context: %{},
        status: :pending
      }

      assert {:ok, %ToolExecution{status: :complete, result: "hello\n"}} =
               ToolExecution.execute(exec)
    end

    test "fails when tool returns {:error, reason}" do
      exec = %ToolExecution{
        tool: __MODULE__.FailingTool,
        input: %{},
        context: %{},
        status: :pending
      }

      assert {:error, %ToolExecution{status: :failed, result: "broken"}} =
               ToolExecution.execute(exec)
    end

    test "suspends when tool returns {:pending, state}" do
      exec = %ToolExecution{
        tool: __MODULE__.PendingTool,
        input: %{"command" => "needs approval"},
        context: %{},
        status: :pending
      }

      assert {:pending,
              %ToolExecution{status: :suspended, suspended_state: %{awaiting: :approval}}} =
               ToolExecution.execute(exec)
    end

    test "sets status to :running during execution" do
      exec = %ToolExecution{
        tool: __MODULE__.StatusCheckTool,
        input: %{},
        context: %{},
        status: :pending
      }

      assert {:ok, %ToolExecution{result: :running}} = ToolExecution.execute(exec)
    end
  end

  describe "resume/2" do
    test "completes when tool approves" do
      exec = %ToolExecution{
        tool: __MODULE__.PendingTool,
        input: %{},
        context: %{},
        status: :suspended,
        suspended_state: %{awaiting: :approval}
      }

      assert {:ok, %ToolExecution{status: :complete, result: "approved result"}} =
               ToolExecution.resume(exec, :approved)
    end

    test "fails when tool denies" do
      exec = %ToolExecution{
        tool: __MODULE__.PendingTool,
        input: %{},
        context: %{},
        status: :suspended,
        suspended_state: %{awaiting: :approval}
      }

      assert {:error, %ToolExecution{status: :failed}} =
               ToolExecution.resume(exec, {:denied, "nope"})
    end
  end

  describe "struct" do
    test "defaults to pending status" do
      exec = %ToolExecution{tool: SkillKit.Tools.Shell, input: %{}, context: %{}}
      assert exec.status == :pending
      assert is_nil(exec.result)
      assert is_nil(exec.suspended_state)
    end

    test "accepts optional skill" do
      skill = %Skill{name: "test:skill", namespace: "test", description: "test", body: "test"}

      exec = %ToolExecution{
        tool: SkillKit.Tools.Shell,
        skill: skill,
        input: %{},
        context: %{}
      }

      assert exec.skill == skill
    end
  end

  # Test helper modules

  defmodule PendingTool do
    @behaviour SkillKit.Tool

    @impl true
    def execute(%ToolExecution{}), do: {:pending, %{awaiting: :approval}}

    @impl true
    def resume(%ToolExecution{}, _state, :approved), do: {:ok, "approved result"}
    def resume(%ToolExecution{}, _state, {:denied, reason}), do: {:error, {:denied, reason}}

    @impl true
    def definition do
      %SkillKit.Tool{name: "pending", description: "test", input_schema: %{}}
    end
  end

  defmodule FailingTool do
    @behaviour SkillKit.Tool

    @impl true
    def execute(%ToolExecution{}), do: {:error, "broken"}

    @impl true
    def resume(_, _, _), do: {:error, "broken"}

    @impl true
    def definition do
      %SkillKit.Tool{name: "failing", description: "test", input_schema: %{}}
    end
  end

  defmodule StatusCheckTool do
    @behaviour SkillKit.Tool

    @impl true
    def execute(%ToolExecution{status: status}), do: {:ok, status}

    @impl true
    def resume(_, _, _), do: {:ok, :resumed}

    @impl true
    def definition do
      %SkillKit.Tool{name: "status_check", description: "test", input_schema: %{}}
    end
  end
end
