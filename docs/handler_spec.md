# Agent Skills Tool Spec

## Overview

The tool is a synchronous tool call. The LLM decides what command to run and how to shape its output — including filtering, piping, and timeouts. The tool's only job is to run the skill and return a result.

Skills are always OS commands. Any Elixir logic that needs to run as a skill is invoked via the shell (`mix run`, `elixir script.exs`, or a compiled binary). The tool stays dumb.

---

## Design Constraints

- **cmd only** — skills are filesystem artifacts defined by `SKILL.md`. The tool always spawns an OS process.
- **No streaming** — output is buffered and returned as a single result. If output is too large to buffer, it's too large to be a useful LLM tool result.
- **No timeouts** — the tool blocks until the process exits or dies. Timeouts are expressed in the command itself (e.g. `timeout 30 run-tests`).
- **No piping helpers** — if the LLM needs filtered output it tells the command to do it (e.g. `run-tests | grep FAILED`).

---

## Execution

Spawns an OS process via `Port`. Stderr is merged into stdout — the LLM sees all output in a single result. If a skill needs to suppress or redirect stderr it does so in the command itself (`my-command 2>/dev/null`). Returns the full output on success or the output + exit code on failure.

The tool reads optional `:cwd` and `:env` keys from the context map:

- **`:cwd`** — working directory for the spawned process. Passed to Port as `{:cd, path}`. When absent, the process inherits the BEAM's working directory.
- **`:env`** — list of `{name, value}` string tuples. Merged with `System.get_env()` (caller-supplied vars override existing ones) and passed to Port as `{:env, charlist_pairs}`. When absent, the process inherits the BEAM's environment.

```elixir
ToolExecution.start("run-tests | grep FAILED")
ToolExecution.start("timeout 30 build")
```

---

## Return Values

```elixir
{:ok, output}              # success — full stdout as binary
{:error, {output, code}}   # failure — any output before exit + exit code
```

---

## Implementation

```elixir
defmodule SkillKit.Tools.Shell do
  @behaviour SkillKit.Tool

  @impl true
  def execute(command, context) do
    opts = [:binary, :exit_status, :stderr_to_stdout] ++ port_opts(context)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("sh")},
        [args: ["-c", command]] ++ opts
      )

    collect(port, [])
  end

  defp port_opts(context) do
    []
    |> maybe_add_cd(context)
    |> maybe_add_env(context)
  end

  defp maybe_add_cd(opts, %{cwd: cwd}) when is_binary(cwd), do: [{:cd, cwd} | opts]
  defp maybe_add_cd(opts, _context), do: opts

  defp maybe_add_env(opts, %{env: env}) when is_list(env) do
    merged =
      System.get_env()
      |> Map.merge(Map.new(env))
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    [{:env, merged} | opts]
  end
  defp maybe_add_env(opts, _context), do: opts

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}}        -> collect(port, [acc | data])
      {^port, {:exit_status, 0}}    -> {:ok, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, code}} -> {:error, {IO.iodata_to_binary(acc), code}}
    end
  end
end
```

Uses `{:spawn_executable, path}` with explicit `args` rather than `{:spawn, command}` to avoid shell re-interpolation at the Port level.

---

## Caller Patterns

### LLM tool result

```elixir
case ToolExecution.start("run-tests") do
  {:ok, output}            -> send_tool_result(llm, output)
  {:error, {output, code}} -> send_tool_error(llm, code, output)
end
```

### From orchestration layer

The tool is always called from `Subagent.Skill`, which runs in its own process under `Agent.SubagentSupervisor`. The tool blocks that process — the parent agent remains free to handle other messages.

```elixir
defmodule Subagent.Skill do
  use GenServer

  def handle_info(:run, state) do
    result = ToolExecution.start(state.cmd)
    send(state.parent, {:subagent_result, self(), result})
    {:stop, :normal, state}
  end
end
```

---

## What the LLM Controls

Policy decisions belong in the skill invocation, not the tool:

| Concern | How |
|---|---|
| Timeout | `timeout 30 my-command` |
| Filtering | `my-command \| grep FAILED` |
| Structured output | `my-command \| jq '.items[]'` |
| Log tailing | `tail -n 100 app.log` |

---

## Relationship to the Execution Pipeline

This spec describes the innermost execution layer — the Port wrapper. In the SkillKit architecture, it sits at the bottom of a three-layer stack:

| Layer | Module | Role |
|---|---|---|
| **ToolExecution** | `SkillKit.ToolExecution` | Named step execution (pre-hooks → execute → post-hooks), suspension/resumption |
| **Orchestrator** | `SkillKit.ToolExecution` | Builds executions, collects hooks from registry, convenience `start/4` |
| **Shell** | `SkillKit.Tools.Shell` | This spec — Port wrapper, cwd/env, output collection |

`Tools.Shell` implements the `SkillKit.Tool` contract (`execute/1`, `resume/3`). It is never called directly by consumers — `SkillKit.ToolExecution.start/4` is the public entry point.

---

## Open Considerations

### Output size

No hard limit is enforced. If a skill can produce unbounded output, it should write to a file and return the path instead.

### Cancellation

Handled by OTP process lifecycle. The tool runs inside a `Subagent.Skill` GenServer. When the parent agent's supervisor kills the subagent process, Erlang closes the port. The OS process receives SIGHUP when its stdin closes. Skills that need graceful shutdown should trap SIGHUP. No explicit `cancel/1` API is needed — the OTP supervision tree is the cancellation mechanism.
