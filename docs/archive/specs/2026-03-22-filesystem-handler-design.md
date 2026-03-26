# Filesystem Handler Design

## Problem

The only way agents can read and write files is through bash commands (`cat`, `echo >`, `sed`). This is error-prone (escaping issues), not hookable at the file-operation level, and not authorizable with granular scopes.

## Design

### Handler

`SkillKit.Tools.Filesystem` — implements `SkillKit.Tool`. One module providing three tools: `read`, `write`, `edit`.

#### Tool Definitions

```
read(path: "lib/skill_kit.ex")
read(path: "lib/skill_kit.ex", offset: 50, limit: 100)

write(path: "lib/skill_kit.ex", content: "full file content")

edit(path: "lib/skill_kit.ex", old_string: "def foo", new_string: "def bar")
edit(path: "lib/skill_kit.ex", old_string: "def foo", new_string: "def bar", replace_all: true)
```

- **read**: Returns file contents. Optional `offset` (line number to start) and `limit` (number of lines). Returns `{:error, :enoent}` for missing files.
- **write**: Creates or overwrites a file. Creates parent directories if needed.
- **edit**: Exact string replacement. `old_string` must be found in the file (returns error if not found or if ambiguous — multiple matches without `replace_all: true`).

#### Execute interface

The `execute/2` function receives a map command:

```elixir
execute(%{"operation" => "read", "path" => "lib/foo.ex"}, context)
execute(%{"operation" => "write", "path" => "lib/foo.ex", "content" => "..."}, context)
execute(%{"operation" => "edit", "path" => "lib/foo.ex", "old_string" => "...", "new_string" => "..."}, context)
```

All paths are resolved relative to `context.cwd` (the agent's workspace from Definition). Absolute paths are rejected. Paths containing `..` that resolve outside the workspace are rejected.

#### Tool definitions

The behaviour currently has `definition/0` (singular). Since Filesystem provides three tools, we add `definitions/0` (plural) that returns a list. `definition/0` remains for single-tool handlers like Shell. ToolBuilder checks for both.

### Configurable Handler List

```elixir
config :skill_kit, :handlers, [SkillKit.Tools.Shell, SkillKit.Tools.Filesystem]
```

Defaults to `[SkillKit.Tools.Shell]` (backward compatible). ToolBuilder reads this config to build the handler tool list.

### Server Routing

`execute_command` dispatches based on tool call name:

- `bash` → goes through `Handler.run/3` (Shell via hook pipeline)
- `read`, `write`, `edit` → goes through `Handler.run/3` (Filesystem via hook pipeline)

The handler module is determined by matching the tool call name against the tool definitions from each configured handler. This is a lookup, not hardcoded name checks.

### Hook Integration

Since handler calls go through the `Execution` pipeline via `Handler.run/3`, hooks fire on Filesystem operations. Hook matchers can match `"Filesystem"` to catch all file ops. The hook context includes the command map, so a PostToolUse hook can inspect `command["operation"]` and `command["path"]` to react to specific operations (e.g., writes to `.memory/`).

## Scope

### In scope
- `SkillKit.Tools.Filesystem` with read/write/edit operations
- `definitions/0` (plural) on handler behaviour
- `config :skill_kit, :handlers` — configurable handler list
- Server routing by tool name to correct handler
- Path safety (relative to workspace, no `..` escape)
- Hook integration via existing Execution pipeline

### Out of scope
- Workspace root resolution (layered base_root → workspace → path) — follow-up
- File permission/scope authorization (files:read, files:write scopes)
- Binary file handling (images, PDFs)
- Directory listing tool
- File watching / change detection

## Testing Strategy

- **Unit**: Filesystem.execute read/write/edit operations
- **Unit**: Path safety — reject absolute paths, reject `..` escapes
- **Unit**: Edit — error on not found, error on ambiguous match, replace_all works
- **Unit**: ToolBuilder includes Filesystem tools when configured
- **Unit**: Server routes read/write/edit to Filesystem handler
- **Integration**: Agent uses read + edit in conversation (mocked LLM)
- **Config**: Default handler list is Shell only
