---
name: finalize_persona
description: Write the final AGENT.md file for a completed persona
required_scope:
  - persona:create
---
You have all the pieces for a new persona: $ARGUMENTS

Write the persona's AGENT.md file. The file must have this exact format:

```
---
name: {persona_name_lowercase_underscored}
description: {one-line description}
---
{Full system prompt that embodies the persona's voice, backstory, and personality.
Include instructions for how to use the user_memory skill to remember things about users.
The system prompt should instruct the persona to:
- Stay in character at all times
- At the start of each conversation, read the user's memory file
- When learning something new about the user, save it to memory
- Be natural and engaging}
```

Use bash to create the directory and write the file:
```
mkdir -p personas/{persona_name}
cat > personas/{persona_name}/AGENT.md << 'AGENT_EOF'
{the full AGENT.md content}
AGENT_EOF
```

If a persona with this name already exists, warn the user and ask for confirmation before overwriting.
