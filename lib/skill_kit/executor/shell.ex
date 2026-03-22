defmodule SkillKit.Executor.Shell do
  @moduledoc """
  Default executor that runs commands via the system shell.

  Parses the command string and executes it using `System.cmd/3` through
  the system shell (`/bin/sh -c`). Returns stdout on success, or
  `{output, exit_code}` on failure.

  `resume/3` delegates to `execute/2` — shell commands have no approval
  concept, so resuming just runs the command stored in the frozen state.
  """

  @behaviour SkillKit.Executor.Behaviour

  @impl true
  def execute(command, _context) do
    case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, {output, exit_code}}
    end
  end

  @impl true
  def resume(%{command: command}, :approved, context) do
    execute(command, context)
  end

  def resume(_state, {:denied, reason}, _context) do
    {:error, {:denied, reason}}
  end
end
