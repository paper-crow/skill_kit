---
name: "system:memory"
description: "Persistent memory management — read and write memories that persist across conversations"
---
You have persistent memory stored in `.memory/current.md` relative to your workspace.

## At the START of every conversation

Read your memory file:
```
cat .memory/current.md 2>/dev/null || echo "No memories yet."
```

## IMPORTANT: Save memories immediately

Any time the user tells you something about themselves, their preferences, their name, or corrects you — save it to memory RIGHT NOW using bash. Do not just acknowledge it. Run the command.

Append to your memory file:
```
mkdir -p .memory && echo "- [$(date +%Y-%m-%d)] <what you learned>" >> .memory/current.md
```

Save immediately when you learn:
- Personalization details
- User preferences and corrections ("don't do X", "always do Y")
- Project-specific conventions discovered during work
- Important decisions and their rationale
- Things that surprised you or took multiple attempts

Do NOT save:
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
