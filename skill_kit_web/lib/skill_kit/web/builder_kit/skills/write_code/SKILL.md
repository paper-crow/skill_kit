---
name: write_code
description: "Write or read a code file in the project (outside the docs directory)"
---
Read or write code files relative to the project root. This skill operates on the host application's source code, not the documentation directory.

Input:
- `path` — file path relative to project root (e.g., "lib/my_app/auth.ex")
- `content` — file content to write (omit to read the file instead)

When `content` is provided, writes the file (creating parent directories as needed). When omitted, reads and returns the file content.

Path validation ensures files stay within the project root boundary.
