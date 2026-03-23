---
name: "tools:edit"
description: "File editing guidelines"
---
To edit files in place, use bash:

- Replace first occurrence: `sed -i '' 's/old/new/' path/to/file`
- Replace all occurrences: `sed -i '' 's/old/new/g' path/to/file`
- Delete a line: `sed -i '' '/pattern/d' path/to/file`
- Insert after a line: `sed -i '' '/pattern/a\new line' path/to/file`

For complex multi-line edits, it's safer to read the file, modify it, and write it back rather than using sed. Read the file first to understand the exact content before editing.

After editing, read the modified section to verify your changes are correct.
