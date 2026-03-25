defmodule SkillKit.Handler.Behaviour do
  @moduledoc """
  Callback contract for handler modules.

  Handlers handle the actual command execution. The default handler
  (`SkillKit.Shell`) shells out via `System.cmd/3`. Custom
  handlers can run commands in sandboxes, containers, or as Elixir code.

  ## Three-value return

  - `{:ok, result}` — execution complete
  - `{:error, reason}` — execution failed
  - `{:pending, state}` — needs approval; caller manages the lifecycle
  """

  @callback execute(execution :: SkillKit.Pipeline.t()) ::
              {:ok, any()} | {:error, any()} | {:pending, any()}

  @callback resume(
              execution :: SkillKit.Pipeline.t(),
              state :: any(),
              decision :: :approved | {:denied, any()}
            ) ::
              {:ok, any()} | {:error, any()} | {:pending, any()}

  @callback tool_definition() :: SkillKit.Handler.ToolDefinition.t()
end
