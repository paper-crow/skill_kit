---
name: "tools:bash"
description: "Shell command execution guidelines"
---
You can execute any shell command including:
- File operations (cat, ls, mkdir, cp, mv, rm)
- HTTP requests (curl, wget)
- Git operations (git status, git diff, git log)
- Text processing (grep, sed, awk, sort, jq)
- System inspection (ps, env, which, uname)

When reading files, prefer `cat` for full contents or `head -n`/`tail -n` for portions.
When writing files, use `tee` or redirect (`>`/`>>`). For multi-line content, use heredocs:
```
cat << 'EOF' > filename
content here
EOF
```

Always quote file paths that contain spaces. Prefer absolute paths when the working directory is uncertain.
