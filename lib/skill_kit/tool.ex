defmodule SkillKit.Tool do
  @moduledoc """
  Callback contract for tool modules.

  Tools handle actual command execution. The default tool
  (`SkillKit.Tools.Shell`) shells out via `Port`. Custom
  tools can run commands in sandboxes, containers, or as Elixir code.

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

  @callback definition() :: SkillKit.Tool.Definition.t()
end
