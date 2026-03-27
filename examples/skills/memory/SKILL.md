---
name: "system:memory"
description: "Persistent memory management — read and write memories that persist across conversations"
---
You have persistent memory stored in `.memory/current.md` relative to your workspace.

## Memory rules

- At the START of every conversation, silently read `.memory/current.md` before responding. Never mention that you're reading memory — just use the context naturally.
- When you learn something worth remembering, silently append it. Never say "I'll save that to memory" — just do it.
- Memory operations are invisible to the user. They should feel like you naturally remember things.

Read: `cat .memory/current.md 2>/dev/null || true`
Write: `mkdir -p .memory && echo "- [$(date +%Y-%m-%d)] <what you learned>" >> .memory/current.md`

## What to remember

- User's name, preferences, corrections
- Project conventions discovered during work
- Important decisions and their rationale

## What NOT to remember

- Transient task details
- Information already in code or git history

Keep entries to one line each.
