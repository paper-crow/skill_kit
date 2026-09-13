# Skill File Format

SkillKit uses the [Agent Skills](https://agentskills.io) open standard for
defining skills. This guide covers the file format, frontmatter fields,
and template tokens available when writing skill files.

For how skills are loaded and registered, see the [Providers](providers.md) guide.

## The `SKILL.md` file

Each skill is defined in a `SKILL.md` file inside a named directory, following
the [Agent Skills](https://agentskills.io/specification) and
[Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins)
conventions. The file combines YAML frontmatter with a markdown prompt body:

```markdown
---
name: "files:read"
description: Read the contents of a file at the given path.
---
Read the file at $ARGUMENTS and return its full contents.
```

The frontmatter section (between `---` delimiters) contains metadata. Everything
below the closing `---` is the skill body — the prompt template that gets
rendered when the skill is activated.

## Frontmatter fields

### Required

| Field         | Type     | Constraints                                  |
|---------------|----------|----------------------------------------------|
| `name`        | string   | Must follow `"namespace:skill_name"` format. Both segments must be lowercase, start with a letter, and match `^[a-z][a-z0-9_-]*$`. |
| `description` | string   | Non-empty. Describes what the skill does and when to use it. |

### Optional

| Field            | Type             | Default | Notes |
|------------------|------------------|---------|-------|
| `required_scope` | list or string   | `[]`    | Scope strings required for authorization. A single string is coerced to a one-element list. |
| `metadata`       | map              | `%{}`   | Arbitrary key-value pairs for custom metadata. |
| `hooks`          | map              | `%{}`   | Lifecycle hooks scoped to this skill. See [Hooks and Execution](hooks-and-execution.md). |

### Example with all fields

```markdown
---
name: "admin:purge"
description: Purge stale records from the database.
required_scope:
  - "admin:write"
  - "audit:log"
metadata:
  author: platform-team
  version: "1.2"
hooks:
  PreToolUse:
    - matcher: "bash"
      hooks:
        - type: command
          command: "check-policy $TOOL_NAME"
  PostToolUse:
    - matcher: ".*"
      hooks:
        - type: http
          url: "https://audit.example.com/log"
  PreSubagent:
    - matcher: ".*"
      hooks:
        - type: command
          command: "echo delegating to subagent"
---
Purge all records older than $ARGUMENTS days.
```

## Template tokens

The skill body supports token substitution at activation time. These tokens
are replaced with runtime values before the rendered body is returned.

### Argument tokens

| Token            | Description |
|------------------|-------------|
| `$ARGUMENTS`     | All arguments as a single string. |
| `$ARGUMENTS[N]`  | Positional argument by 0-based index (space-split). |
| `$N`             | Shorthand for `$ARGUMENTS[N]` (e.g. `$0`, `$1`). |

If `$ARGUMENTS` (or any `$N` token) is **not** present in the body but
arguments are provided, `\n\nARGUMENTS: <value>` is appended automatically.

### Context tokens

| Token                    | Description |
|--------------------------|-------------|
| `$SKILL_DIR`             | Directory containing the skill file. |
| `$SESSION_ID`            | Current session identifier. |
| `${CLAUDE_SKILL_DIR}`    | Alias for `$SKILL_DIR` (Claude Code compatibility). |
| `${CLAUDE_SESSION_ID}`   | Alias for `$SESSION_ID` (Claude Code compatibility). |

### Scope variables

When a scope struct implementing `SkillKit.Scope` is provided, any remaining
`$VAR` or `${VAR}` tokens are resolved via `Scope.resolve/3`. Unresolved
variables are left as-is.

```markdown
---
name: "team:greeting"
description: Greet the current user.
---
Hello $USERNAME, welcome to $TENANT.
```

If the scope's `resolve/3` returns `{:ok, "alice"}` for `"USERNAME"` and
`{:ok, "acme"}` for `"TENANT"`, the rendered body becomes
`Hello alice, welcome to acme.`

### Dynamic commands

The `` !`<command>` `` syntax executes a shell command during rendering and
replaces the token with the command's output. This is preprocessing — the
LLM receives the final output, not the command.

```markdown
---
name: "git:context"
description: Gather git context for the current branch.
---
Current branch: !`git branch --show-current`
Recent commits: !`git log --oneline -5`
```

> **Security — disabled by default.** These commands run with the host
> process's OS permissions and bypass tool scope, so they are a
> code-execution vector when skill sources are not fully trusted. Rendering
> leaves the `` !`cmd` `` tokens untouched unless you explicitly opt in:
>
> ```elixir
> config :skill_kit, :allow_dynamic_commands, true
> ```

## Naming conventions

SkillKit uses a `"namespace:skill_name"` naming scheme:

- **namespace** — groups related skills (e.g. `files`, `admin`, `tools`)
- **skill_name** — identifies the specific skill within the namespace

Both segments must start with a lowercase letter and contain only lowercase
letters, digits, hyphens, and underscores.

When using the Local provider, the namespace comes from the kit (directory)
name and the skill name from the frontmatter `name` field. The fully-qualified
name is `"<kit_name>:<skill_name>"`.

## Authorization and permissions

Different platforms handle skill authorization differently:

- **Agent Skills spec** ([agentskills.io](https://agentskills.io/specification)):
  Defines `allowed-tools` for pre-approving tool access. Authorization is
  left to the host agent.
- **Claude Code** ([code.claude.com](https://code.claude.com/docs/en/skills)):
  Uses `allowed-tools`, `disable-model-invocation`, and `user-invocable`
  frontmatter fields to control who can invoke a skill and what tools it
  can access. Permission rules like `Skill(name)` restrict Claude's access.

SkillKit uses `required_scope` for authorization. Scopes are checked against
the caller's permissions (provided via a struct implementing `SkillKit.Scope`)
at both discovery and activation time. See [Authorization](authorization.md)
for the full model.

## Relationship to the Agent Skills standard

SkillKit's skill format is compatible with the
[Agent Skills specification](https://agentskills.io/specification). Key
differences:
- **Authorization**: Agent Skills uses `allowed-tools`. SkillKit uses
  `required_scope` for scope-based access control.
- **Template tokens**: `$ARGUMENTS`, `$N`, `$SKILL_DIR`, and `$SESSION_ID`
  are shared with Claude Code. SkillKit adds scope variable resolution.
- **Progressive disclosure**: Both follow the same three-tier model — metadata
  at discovery, full body at activation, supporting files on demand.
