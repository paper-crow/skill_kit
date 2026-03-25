---
name: user_memory
description: Read and write persistent memories about the current user
---
You have access to a persistent memory file for the current user.

**Memory file location:** data/memories/$PERSONA/$USERNAME.md

## Reading memories
At the start of a conversation, read the memory file to recall what you know:
```
cat data/memories/$PERSONA/$USERNAME.md 2>/dev/null || echo "No memories yet for this user."
```

## Writing memories
When you learn something new about the user (preferences, facts, interests, their name), save it:
```
mkdir -p data/memories/$PERSONA
cat >> data/memories/$PERSONA/$USERNAME.md << 'EOF'
- {what you learned} ({date or context})
EOF
```

## Guidelines
- Read memories at the start of every conversation
- Save memories naturally — don't announce that you're saving unless asked
- Keep entries concise — one line per fact
- Don't duplicate entries you've already saved
