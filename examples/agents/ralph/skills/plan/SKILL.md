---
name: plan
description: Generate a TODO file from a goal. Pass the user's full request as arguments.
---
The user's request: $ARGUMENTS

Parse the destination path and goal from the request. Write a TODO
file at that path with this structure:

- One `## MVP` section using `- [ ]` checkboxes.
- Each item must be **verifiable** — a test, a check, or an
  observable output proves it done.
- Each item must be roughly **one iteration of work** — small but
  real. Not "fix the API"; not "rename a variable on line 42".
- Order items by dependency. The top item is the next thing to do.
- Optional `## FUTURE` section for nice-to-haves you want to defer.
  Items here will not block Ralph from declaring DONE.

Use the shell tool to write the file. When the file is written,
reply with exactly the word `PLANNED` — no preamble, no commentary.
