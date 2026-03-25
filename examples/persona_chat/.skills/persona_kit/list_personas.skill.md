---
name: list_personas
description: List all available personas
---
## Available personas

!`for dir in personas/*/; do if [ -f "$dir/AGENT.md" ]; then name=$(head -5 "$dir/AGENT.md" | grep "^name:" | sed 's/name: //'); desc=$(head -5 "$dir/AGENT.md" | grep "^description:" | sed 's/description: //'); echo "- $name: $desc"; fi; done`

To chat with a persona, run:
`mix persona_chat --user $USERNAME --persona PERSONA_NAME`

If the list above is empty, tell the user they have no personas yet and suggest creating one.
