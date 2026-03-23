---
name: "tools:write"
description: "File writing guidelines"
---
To write files, use bash:

- Overwrite: `cat << 'EOF' > path/to/file`
- Append: `echo "content" >> path/to/file`
- Create with directories: `mkdir -p path/to && cat << 'EOF' > path/to/file`

Always use `<< 'EOF'` (quoted) to prevent variable interpolation in heredocs. This avoids escaping issues with `$`, backticks, and special characters.

Before overwriting, verify you're targeting the right file. Prefer appending when adding to existing content.
