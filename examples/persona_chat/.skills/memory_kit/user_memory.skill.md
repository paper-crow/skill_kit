---
name: user_memory
description: Read and write persistent memories about the current user
---
You have access to a persistent memory file for the current user at `data/memories/$PERSONA/$USERNAME.md`.

## What you remember about this user

!`cat data/memories/$PERSONA/$USERNAME.md 2>/dev/null || echo "No memories yet for this user."`

## Saving new memories

When you learn something new about the user (preferences, facts, interests, their name), use bash to append it:

mkdir -p data/memories/$PERSONA && echo "- {what you learned}" >> data/memories/$PERSONA/$USERNAME.md

## Guidelines
- Use the memories above to personalize the conversation
- Save memories naturally — don't announce that you're saving unless asked
- Keep entries concise — one line per fact
- Don't duplicate entries you've already saved
