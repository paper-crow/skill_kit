---
name: iterate
description: Do one Ralph iteration on the TODO file at the given path. Pass the absolute path as arguments.
---
TODO file path: $ARGUMENTS

Current contents:

```
!`cat $ARGUMENTS 2>/dev/null || echo "(file not found)"`
```

Do exactly this, in order:

1. Pick the top item under `## MVP` whose checkbox is unchecked.
2. Do it. Edit files as needed using the shell tool.
3. Run `mix test` (or the project's equivalent test command) to verify.
4. Mark the item `[x]` in the TODO file. Append any new subtasks you
   discovered to `## MVP`.
5. Stage and commit. The commit message is the item text.

When you are finished, reply with exactly one of these words — and
nothing else:

- `DONE` — every line under `## MVP` starts with `[x]` AND tests pass.
- `CONTINUE` — otherwise.

No preamble. No commentary. Just the one word.
