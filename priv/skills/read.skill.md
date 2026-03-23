---
name: "tools:read"
description: "File reading guidelines"
---
To read files, use bash:

- Full file: `cat path/to/file`
- First N lines: `head -n 50 path/to/file`
- Last N lines: `tail -n 50 path/to/file`
- Line range: `sed -n '10,30p' path/to/file`
- With line numbers: `cat -n path/to/file`
- Check if exists: `test -f path/to/file && echo exists || echo not found`

For large files, read in sections rather than dumping the entire contents. Start with `wc -l` to check the size.
