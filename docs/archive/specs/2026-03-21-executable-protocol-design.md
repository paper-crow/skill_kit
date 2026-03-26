# Executable Protocol & Handler Architecture

> **References:**
> - [Agent Skills Specification](https://agentskills.io/specification)
> - [Agent Skills Client Implementation Guide](https://agentskills.io/client-implementation/adding-skills-support)
> - [Claude Code Skills](https://code.claude.com/docs/en/skills)
> - [Claude Code Hooks](https://code.claude.com/docs/en/hooks)
> - [Claude Code Plugins Reference](https://code.claude.com/docs/en/plugins-reference)

## Problem

The current `SkillKit.Skill` module conflates data, behaviour contract, and execution dispatch. Skills have a `:type` field (`:code` | `:prompt`) with pattern-matched execution paths and 4 behaviour callbacks (`name/0`, `description/0`, `required_scope/0`, `execute/2`). This doesn't match how skills actually work: they're markdown documents loaded from disk that get injected into LLM context. The LLM reads the skill body, decides what command to run, and passes that command back for execution.

The [Agent Skills open standard](https://agentskills.io) and [Claude Code plugin model](https://code.claude.com/docs/en/plugins-reference) confirm this architecture: skills are prompt content with metadata, execution is the agent harness's responsibility, and hooks intercept tool/command invocations system-wide.

## Design

### Skill Struct (simplified)

`%SkillKit.Skill{}` becomes pure data. The behaviour callbacks and `:type`/`:module` fields are removed. An `:handler` field holds the module responsible for running commands, defaulting to `SkillKit.Tools.Shell`. A `:hooks` field holds hook definitions that fire when *any* skill executes a command.

```elixir
defstruct [
  :name,            # "namespace:skill-name" — colon-separated, prevents collisions
  :namespace,       # extracted namespace segment
  :description,     # human-readable — used for progressive disclosure catalog
  :body,            # markdown skill instructions (SKILL.md body after frontmatter)
  :location,        # absolute path to SKILL.md (aligned with Agent Skills spec)
  required_scope: [],
  tool: SkillKit.Tools.Shell,
  hooks: []         # list of %Hook{} definitions — scoped to skill lifetime
]
```

Removed fields: `:type`, `:module`.
Removed: `@behaviour SkillKit.Skill` and all 4 callbacks.
New fields: `:handler`, `:hooks`.

> **CHANGED from v1:** The handler field is only set at runtime registration, never parsed from YAML frontmatter. This preserves the `atoms: false` YAML security policy — no string-to-atom conversion from untrusted skill files. The Loader does not parse `handler` from frontmatter.

> **CHANGED from v1:** `Skill.execute/3` is removed entirely. The orchestrator (`SkillKit.ToolExecution.start/4`) is the sole public entry point for execution. This prevents bypassing hooks via a convenience wrapper on the struct.

### Rendering (preprocessing — separate from execution)

> **CHANGED from v1:** `interpolate/2` is replaced by `SkillKit.Skill.render/2`, a preprocessing step that runs *before* the skill body enters LLM context. This is not execution — it's template expansion.

Claude Code skills support string substitutions that are resolved before the LLM sees the content ([docs](https://code.claude.com/docs/en/skills#pass-arguments-to-skills)):

| Variable | Description |
|----------|-------------|
| `$ARGUMENTS` | All arguments passed when invoking the skill |
| `$ARGUMENTS[N]` / `$N` | Positional argument by 0-based index |
| `${CLAUDE_SESSION_ID}` | Current session ID |
| `${CLAUDE_SKILL_DIR}` | Directory containing the SKILL.md file |
| `` !`command` `` | Shell command output injected inline (dynamic context) |

`SkillKit.Skill.render/2` handles the first four. The `` !`command` `` syntax (dynamic context injection) is a separate concern that invokes the handler pipeline and should be handled by the host application or a dedicated rendering step.

```elixir
@spec render(t(), map()) :: {:ok, String.t()} | {:error, term()}
def render(%__MODULE__{body: body}, args) do
  # Substitute $ARGUMENTS, $ARGUMENTS[N], $N, ${CLAUDE_SKILL_DIR}, etc.
  # Return the rendered body string
end
```

This is the evolution of the old `interpolate/2` — same concept (template expansion), but with the correct substitution vocabulary and correctly positioned as a pre-context step rather than an execution step.

### Handler Behaviour

A simple contract that any handler module must implement:

```elixir
defmodule SkillKit.Tool do
  @callback execute(command :: String.t(), context :: map()) ::
              {:ok, any()} | {:error, any()} | {:pending, state :: any()}

  @callback resume(state :: any(), decision :: :approved | {:denied, reason :: any()}, context :: map()) ::
              {:ok, any()} | {:error, any()} | {:pending, state :: any()}
end
```

- `command` is always a string (the shell command or equivalent).
- `context` is the execution context map (see Context Structure below).

**Three-value return:**
- `{:ok, result}` — execution complete, return result.
- `{:error, reason}` — execution failed.
- `{:pending, state}` — execution needs approval. The handler freezes its state into `state` (opaque to the orchestrator). The caller is responsible for managing the approval lifecycle and calling `resume/3` with the decision.

The `resume/3` callback accepts the frozen state, an approval decision, and the context. It can itself return `{:pending, state}` for multi-step approval flows, though single-step is the expected common case.

> **Design note:** The handler behaviour stays synchronous and process-agnostic. It returns data, not processes. The host application wraps execution in a GenServer (or similar) to handle the async approval lifecycle — parking the state, surfacing the request, and resuming on decision. This keeps the handler testable and composable without coupling it to OTP process patterns.

### Context Structure

> **CHANGED from v1:** The spec now defines what `context` contains to eliminate ambiguity. There is one context map that flows through the entire pipeline — orchestrator, hooks, and handler all receive the same structure.

```elixir
%{
  skill: %SkillKit.Skill{},     # the skill being executed
  scope: [String.t()],          # granted scopes for the current caller
  session_id: String.t() | nil, # optional session identifier
  # ... host application may add additional keys
}
```

The orchestrator enriches this context before passing it to hooks and the handler. Hook handlers receive a **superset** of this context — the base context plus `command` (the command string) and `handler` (the handler module). See the Hook Struct section for the full hook context shape.

### Handler.Shell (default implementation)

The default handler that shells out via `System.cmd/3`:

```elixir
defmodule SkillKit.Tools.Shell do
  @behaviour SkillKit.Tool

  @impl true
  def execute(command, _context) do
    # Parse and execute the command string via System.cmd/3
    # Return {:ok, stdout} or {:error, {stderr, exit_code}}
  end
end
```

Custom handlers override this — for example, an handler that runs commands in a sandbox, a Docker container, or interprets them as Elixir code.

Shell's `resume/3` delegates to `execute/2` — shell commands have no approval concept, so resuming just runs the command. This is the sensible default: handlers that don't need approval should never return `{:pending, state}` from `execute/2` in the first place, but if `resume/3` is called, executing is better than deadlocking.

### Handler Execution (Ecto.Multi-inspired)

> **CHANGED from v2:** The orchestrator is now a named pipeline data structure, inspired by `Ecto.Multi`. Each step (pre-hook, execute, post-hook) is a named entry in the pipeline. The accumulated results of previous steps are available to subsequent steps. The pipeline can suspend at any step via `{:pending, state}` and resume from that exact point with full history.

`SkillKit.Execution` is the core data structure. Like `Ecto.Multi`, it separates pipeline construction from execution:

```elixir
# Build the pipeline (declarative — no side effects)
pipeline = SkillKit.Execution.new(registry, skill, command, context)

# Run it
{:ok, %Execution{}} | {:pending, %Execution{}} | {:error, %Execution{}}
  = SkillKit.Execution.run(pipeline)

# Resume from suspension
{:ok, %Execution{}} | {:pending, %Execution{}} | {:error, %Execution{}}
  = SkillKit.Execution.resume(pipeline, decision)
```

**Execution struct:**

```elixir
%SkillKit.Execution{
  steps: [
    {:pre_hook, "security-check", hook},
    {:pre_hook, "rate-limiter", hook},
    {:execute, "shell", handler_fn},
    {:post_hook, "sanitizer", hook},
    {:post_hook, "audit-log", hook}
  ],
  results: %{
    "security-check" => :allow,
    "rate-limiter" => {:allow, "modified command"},
    "shell" => {:ok, "output"}          # or {:pending, frozen_state}
    # "sanitizer" not yet reached
  },
  status: :running | :pending | :complete | :failed,
  suspended_at: nil | step_name,        # which step returned {:pending, state}
  context: %{...}                       # execution context (enriched at each step)
}
```

**`Execution.new/4` — construction:**

> **CHANGED from v1:** Hook matchers run against the **handler name** (e.g., `"Shell"`, `"Docker"`, `"Sandbox"`), not the command string. This aligns with Claude Code where `PreToolUse`/`PostToolUse` matchers run against the tool name (e.g., `"Bash"`, `"Edit|Write"`). The hook handler logic then inspects the command/input details.

1. Build the execution context map (skill, scope, session info).
2. Fetch all skills from the registry.
3. Collect all hooks from all skills. Filter by regex match on the **handler name**.
4. Assemble the step list: matched pre-hooks → execute → matched post-hooks. Each step gets a name.
5. Return the `%Execution{}` struct — nothing has executed yet.

**`Execution.run/1` — execution:**

Walks the step list sequentially:

1. **Pre-hook steps:** Run each handler with accumulated context + command. On `:allow`, continue. On `{:allow, cmd}`, update command and continue. On `{:deny, reason}`, set status to `:failed` and stop. On `{:pending, state}`, set status to `:pending`, record `suspended_at`, and return.
2. **Execute step:** Call `skill.handler.execute(command, context)`. On `{:ok, result}`, record and continue. On `{:error, reason}`, set status to `:failed` and stop. On `{:pending, state}`, set status to `:pending`, record `suspended_at`, and return.
3. **Post-hook steps:** Run each handler with accumulated context + result. The handler returns the result the next step (or caller) sees. On `{:ok, result}` or `{:error, reason}`, record and continue. On `{:pending, state}`, set status to `:pending`, record `suspended_at`, and return.
4. When all steps complete, set status to `:complete` and return.

**`Execution.resume/2` — resumption:**

1. Look up `suspended_at` to find which step was pending.
2. Call the appropriate resume function (handler's `resume/3` or hook handler with decision).
3. Record the result and continue walking the remaining steps from that point.
4. The full history of previously completed steps is preserved in `results`.

**Benefits of the pipeline model:**

- **Replay/hydrate** — serialize the pipeline, resume in a different process or after a restart
- **Inspection** — `results` is a complete audit trail of every step
- **Composition** — build pipelines declaratively, test them without executing
- **Suspension at any point** — pre-hooks, handler, and post-hooks can all return `{:pending, state}`
- **Named steps** — like `Ecto.Multi`, each step has a name for lookup and debugging

> **Convenience:** `SkillKit.ToolExecution.start/4` remains as a shortcut that builds and runs the pipeline in one call, for callers that don't need pipeline inspection or suspension support.

### Hook Struct

> **CHANGED from v1:** Hook handler type is now defined. Matchers target handler name, not command string. Pre-hook and post-hook decision contracts are specified.

Each hook defines a phase, a regex pattern to match against the handler name, and a handler:

```elixir
%SkillKit.Hook{
  phase: :pre | :post,
  matcher: ~r/regex/,       # matched against the handler module name (e.g., "Shell")
  handler: handler           # {module, function, args} tuple or (context -> result) function
}
```

**Handler types:**

Handlers are either MFA tuples or anonymous functions:
- MFA: `{MyApp.Hooks, :validate_command, []}` — called as `MyApp.Hooks.validate_command(hook_context)`
- Function: `fn hook_context -> ... end`

**Hook context (input to handlers):**

Pre-hooks receive:
```elixir
%{
  skill: %Skill{},           # skill being executed
  scope: [String.t()],       # caller's granted scopes
  command: String.t(),        # the command about to be executed
  handler: module()          # the handler module
}
```

Post-hooks receive the same, plus:
```elixir
%{
  ...,                        # all pre-hook fields
  result: {:ok, any()} | {:error, any()}  # execution result
}
```

**Hook decisions (return values):**

Pre-hook handlers must return one of:
- `:allow` — proceed with execution
- `{:allow, updated_command}` — proceed with a modified command
- `{:deny, reason}` — block execution, set status to `:failed`
- `{:pending, state}` — suspend the execution, needs approval before continuing

Post-hook handlers return the result that the next step (or caller) receives:
- `{:ok, result}` — pass through or transform the result
- `{:error, reason}` — replace the result with an error (e.g., blocking after detecting sensitive output)
- `{:pending, state}` — suspend the execution (e.g., "this output contains PII, get approval before returning")

> **Design note:** Pre-hooks short-circuit on the first `:deny`. If multiple pre-hooks match, they run sequentially and each receives the (potentially modified) command from the previous hook. When multiple post-hooks match, they chain — each receives the result returned by the previous hook (or the handler's result for the first hook).

> **Handler name extraction:** The matcher regex runs against the unqualified module name — the last segment after the final dot. `SkillKit.Tools.Shell` becomes `"Shell"`, `MyApp.Handler.Docker` becomes `"Docker"`. Extracted via `Module.split(module) |> List.last()`.

**Hooks are global but lifetime-scoped:**

A hook defined on Skill A fires when Skill B (or any skill) executes via a matching handler. This mirrors Claude Code's `PreToolUse`/`PostToolUse` hooks which fire on any tool call system-wide. However, hooks are scoped to the skill's active lifetime — when a skill is unregistered, its hooks are removed. ([Claude Code hooks docs](https://code.claude.com/docs/en/hooks#hooks-in-skills-and-agents))

**Hooks from frontmatter:**

The Loader parses `hooks` from YAML frontmatter, aligned with the Claude Code skill format:

```yaml
---
name: secure-operations
description: Perform operations with security checks
hooks:
  PreToolUse:
    - matcher: "Shell"
      hooks:
        - type: command
          command: "./scripts/security-check.sh"
---
```

The Loader converts this YAML structure into `%Hook{}` structs. The `type: command` handler type maps to an MFA that shells out to the specified script. Future handler types (`:http`, `:prompt`, `:agent`) can be added later.

### Catalog / Registry Layering

> **CHANGED from v2:** Introduces `SkillKit.Catalog` as the public API layer over the existing Registry. Registry becomes an internal storage module. Authorization moves into the Catalog. Terminology aligned with the [Agent Skills client implementation guide](https://agentskills.io/client-implementation/adding-skills-support).

Three layers, aligned with the Agent Skills standard vocabulary:

| Layer | Module | Role | Public? |
|-------|--------|------|---------|
| **Catalog** | `SkillKit.Catalog` | Public API — discovery, activation, authorization filtering | Yes |
| **Registry** | `SkillKit.Registry` | Low-level GenServer+ETS storage — register, unregister, raw get/list | No (internal) |
| **Authorization** | `SkillKit.Authorization` + `SkillKit.Scope` | Scope matching and filtering logic | No (used by Catalog) |

**Catalog public API:**

```elixir
# Tier 1: Discovery — returns only skills the caller is authorized to see
Catalog.list_skills(catalog, scopes: ["files:*"])
Catalog.get_skill(catalog, "files:read", scopes: ["files:*"])

# Tier 2: Activation — renders the skill body with arguments, ready for LLM context
Catalog.activate(catalog, "files:read", args, scopes: ["files:*"])
# => {:ok, rendered_body} | {:error, :not_found} | {:error, :unauthorized}

# Write operations (pass-through to Registry)
Catalog.register(catalog, %Skill{})
Catalog.unregister(catalog, "files:read")
```

`activate/4` is where `render/2` lives — the Catalog handles the full progression from "give me this skill" to "here's the rendered body ready for LLM context." This maps to the Agent Skills guide's Step 4 (Activate skills).

**Registry stays unchanged internally** — same GenServer+ETS hybrid, same ETS read concurrency. Catalog wraps it and adds authorization. Consumers never call Registry directly.

### Progressive Disclosure

The [Agent Skills client implementation guide](https://agentskills.io/client-implementation/adding-skills-support) defines a three-tier loading strategy that our architecture maps to:

| Tier | What's loaded | SkillKit component | When |
|------|--------------|-------------------|------|
| 1. Discovery | name + description (~50-100 tokens/skill) | `Catalog.list_skills/2` | Session start |
| 2. Activation | Full SKILL.md body, rendered | `Catalog.activate/4` | Skill invoked |
| 3. Execution | Command results via handler pipeline | `Handler.run/4` → `%Execution{}` | LLM issues command |

Authorization filtering happens at tier 1 — filtered skills are hidden entirely from discovery, not listed and blocked at activation time ([client implementation guide](https://agentskills.io/client-implementation/adding-skills-support#filtering)).

## Impact on Existing Code

### Skill module (`lib/skill_kit/skill.ex`)
- Remove `@behaviour` definition and all 4 `@callback` declarations
- Remove `:type` and `:module` from struct
- Remove `execute/3` dispatch (code/prompt pattern match)
- Rename `interpolate/2` → `render/2` with expanded substitution vocabulary (`$ARGUMENTS`, `$N`, `${CLAUDE_SKILL_DIR}`, etc.)
- Add `:handler` and `:hooks` fields
- Rename `:source` → `:location` (aligned with Agent Skills spec)

### Loader module (`lib/skill_kit/loader.ex`)
- Stop setting `type: :prompt` in `build_skill/3`
- Parse `hooks` from frontmatter YAML into `%Hook{}` structs
- Do NOT parse `handler` from frontmatter (security: `atoms: false` policy)
- Set `:location` instead of `:source`

### Registry module (`lib/skill_kit/registry.ex`)
- Remove `load_from_modules/1`, `build_code_skill/1`, `validate_callbacks/1`, `ensure_module_available/1`
- Remove `:skills` opt from `start_link/1`
- Skills are only loaded from disk directories or registered as structs at runtime
- Becomes internal — public API moves to Catalog

### Authorization module (`lib/skill_kit/authorization.ex`)
- Stays as-is internally — logic unchanged
- No longer called directly by consumers — called by Catalog

### Test support (`test/support/test_skills.ex`)
- Remove `SkillKit.TestSkills.Echo` module (behaviour-based code skill)
- Replace with struct-based test fixtures

### New modules
- `SkillKit.Catalog` — public API layer over Registry with authorization filtering and activation
- `SkillKit.Tool` — callback contract for handlers (`execute/2`, `resume/3`)
- `SkillKit.Tools.Shell` — default shell handler via `System.cmd/3`
- `SkillKit.Execution` — named pipeline struct (steps, results, status, suspension point) inspired by `Ecto.Multi`
- `SkillKit.ToolExecution` — builds and runs `%Execution{}` pipelines; convenience `run/4` shortcut
- `SkillKit.Hook` — hook struct with phase, matcher, and handler

## Summary of Changes from v1

| # | Change | Reason |
|---|--------|--------|
| 1 | `Skill.execute/3` removed — `Handler.run/4` is the sole entry point | Prevents bypassing hooks; eliminates bidirectional coupling |
| 2 | `interpolate/2` → `render/2` with `$ARGUMENTS`, `$N`, `${CLAUDE_SKILL_DIR}` substitutions | Aligns with Claude Code skill substitution vocabulary; correctly positioned as pre-context preprocessing |
| 3 | Hook matchers target **handler name**, not command string | Aligns with Claude Code where `PreToolUse` matchers target tool name, not tool input |
| 4 | Hook handler defined as MFA or function, not TBD | Unblocks orchestrator implementation |
| 5 | Pre-hook decision contract: `:allow`, `{:allow, cmd}`, `{:deny, reason}` | Defines rejection mechanism; first deny short-circuits |
| 6 | Post-hook decision contract: `:ok`, `{:block, reason}` | Post-hooks observe but can signal downstream failure |
| 7 | Single context map flows through entire pipeline | Eliminates three different meanings of "context" |
| 8 | Handler field set at runtime only, not from YAML | Preserves `atoms: false` security policy |
| 9 | Hooks parsed from frontmatter YAML aligned with Claude Code format | Skills can define lifecycle hooks in the same format as Claude Code |
| 10 | Progressive disclosure tiers mapped to SkillKit components | Confirms render and execute are separate concerns |
| 11 | Handler returns `{:pending, state}` for approval flows | Keeps handler synchronous and process-agnostic; host app wraps in GenServer for async lifecycle |
| 12 | `resume/3` callback on handler behaviour | Allows resuming frozen execution with approval decision; supports multi-step approval |
| 13 | `Handler.resume/5` on orchestrator | Resumes pending execution through the hook pipeline; post-hooks run after approval completes |
| 14 | Orchestrator is now `%Execution{}` pipeline (Ecto.Multi pattern) | Named steps, accumulated results, suspend/resume at any point, full audit trail |
| 15 | Pre-hooks and post-hooks can return `{:pending, state}` | Any step in the pipeline can suspend, not just the handler |
| 16 | Renamed Pipeline → ToolExecution | It's what it is — an execution with steps, not an abstract pipeline |
| 17 | `SkillKit.Catalog` as public API over Registry | Aligns with Agent Skills terminology; Registry becomes internal storage |
| 18 | Authorization moves into Catalog | Filtering happens at discovery (tier 1) — filtered skills never appear |
| 19 | `Catalog.activate/4` introduces activation as a named concept | Maps to Agent Skills tier 2; render/2 lives here |
| 20 | `:source` → `:location` | Aligned with Agent Skills spec field name |
