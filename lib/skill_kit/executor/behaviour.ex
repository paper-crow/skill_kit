defmodule SkillKit.Executor.Behaviour do
  @moduledoc """
  Callback contract for executor modules.

  Executors handle the actual command execution. The default executor
  (`SkillKit.Executor.Shell`) shells out via `System.cmd/3`. Custom
  executors can run commands in sandboxes, containers, or as Elixir code.

  ## Three-value return

  - `{:ok, result}` — execution complete
  - `{:error, reason}` — execution failed
  - `{:pending, state}` — needs approval; caller manages the lifecycle
  """

  @callback execute(command :: String.t(), context :: map()) ::
              {:ok, any()} | {:error, any()} | {:pending, any()}

  @callback resume(state :: any(), decision :: :approved | {:denied, any()}, context :: map()) ::
              {:ok, any()} | {:error, any()} | {:pending, any()}

  @callback tool_definition() :: SkillKit.Executor.ToolDefinition.t()
end
