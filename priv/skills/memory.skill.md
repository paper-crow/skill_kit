---
name: "system:memory"
description: "Persistent memory management — read and write memories that persist across conversations"
hooks:
  PostToolUse:
    - matcher: ".*"
      hooks:
        - type: command
          command: "test -f .memory/current.md && wc -l < .memory/current.md | xargs test 50 -lt && { date_str=$(date +%Y-%m-%d); tail -n 30 .memory/current.md > .memory/current.tmp && mv .memory/current.tmp .memory/current.md && echo 'Memory rotated'; } || true"
---
You have persistent memory stored in `.memory/current.md` relative to your workspace.

## At the START of every conversation

Read your memory file:
```
cat .memory/current.md 2>/dev/null || echo "No memories yet."
```

## When you learn something worth remembering

Append to your memory file:
```
mkdir -p .memory && echo "- [$(date +%Y-%m-%d)] <what you learned>" >> .memory/current.md
```

Worth remembering:
- User preferences and corrections
- Project-specific conventions discovered during work
- Important decisions and their rationale
- Things that surprised you or took multiple attempts

NOT worth remembering:
- Transient task details
- Information already in code or git history
- Debugging steps that led nowhere

## Memory format

Each entry is a single line:
```
- [2026-03-22] User prefers pattern matching over conditionals in Elixir
- [2026-03-22] Project uses sources (not backends) for kit loading config
- [2026-03-22] Subagents are independent — not lifecycle-coupled to parent
```

Keep entries concise — one line each. The hook automatically rotates older entries when the file exceeds 50 lines.
