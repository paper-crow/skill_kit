defmodule SkillKit.Executor.Shell do
  @moduledoc """
  Default executor that runs commands via the system shell.

  Executes the command string using `Port.open/2` with `:stderr_to_stdout`.
  Returns stdout on success, or `{output, exit_code}` on failure.

  `resume/3` delegates to `execute/2` — shell commands have no approval
  concept, so resuming just runs the command stored in the frozen state.
  """

  @behaviour SkillKit.Executor.Behaviour

  @impl true
  def execute(command, _context) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("sh")},
        [:binary, :exit_status, :stderr_to_stdout, args: ["-c", command]]
      )

    collect(port, [])
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc | data])
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, code}} -> {:error, {IO.iodata_to_binary(acc), code}}
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
