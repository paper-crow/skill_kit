defmodule SkillKit.Tool do
  @moduledoc """
  Describes a tool the LLM can call and defines the callback contract
  for tool implementations.

  ## Struct

  The `%Tool{}` struct describes a tool for the LLM's tool-use schema:

      %SkillKit.Tool{name: "bash", description: "Execute a shell command", input_schema: %{...}}

  ## Behaviour

  Tool implementations must implement three callbacks:

  - `execute/1` — run the tool, receiving a `%SkillKit.ToolExecution{}`
  - `resume/3` — resume after suspension
  - `definition/0` — return a `%SkillKit.Tool{}` describing the tool

  ## Three-value return

  - `{:ok, result}` — execution complete
  - `{:error, reason}` — execution failed
  - `{:pending, state}` — needs approval; caller manages the lifecycle
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @enforce_keys [:name, :description, :input_schema]
  defstruct [:name, :description, :input_schema]

  @callback execute(execution :: SkillKit.ToolExecution.t()) ::
              {:ok, any()} | {:error, any()} | {:pending, any()}

  @callback resume(
              execution :: SkillKit.ToolExecution.t(),
              state :: any(),
              decision :: :approved | {:denied, any()}
            ) ::
              {:ok, any()} | {:error, any()} | {:pending, any()}

  @callback definition() :: t()
end
