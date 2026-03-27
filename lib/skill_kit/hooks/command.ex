defmodule SkillKit.Hooks.Command do
  @moduledoc """
  Hook handler that shells out to a command.

  Exit code semantics (matching Claude Code):
  - `0` — `:ok` (allow)
  - `2` — `{:deny, output}` (block)
  - Other — `:ok` (non-blocking error)

  The hook context is passed as JSON in the `HOOK_INPUT` environment variable.
  """

  @behaviour SkillKit.Hooks.Handler

  @impl true
  def execute(%{"command" => cmd}, context) do
    input_json = Jason.encode!(context)

    case System.cmd("sh", ["-c", cmd],
           stderr_to_stdout: true,
           env: [{"HOOK_INPUT", input_json}]
         ) do
      {_output, 0} -> :ok
      {output, 2} -> {:deny, String.trim(output)}
      {_output, _code} -> :ok
    end
  end
end
