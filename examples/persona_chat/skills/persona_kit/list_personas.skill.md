---
name: list_personas
description: List all available personas
---
List the available personas by reading the personas/ directory.

Use bash to find all AGENT.md files and extract their name and description from the YAML frontmatter:

```
for dir in personas/*/; do
  if [ -f "$dir/AGENT.md" ]; then
    name=$(head -5 "$dir/AGENT.md" | grep "^name:" | sed 's/name: //')
    desc=$(head -5 "$dir/AGENT.md" | grep "^description:" | sed 's/description: //')
    echo "- $name: $desc"
  fi
done
```

Present the list to the user. If no personas exist, suggest creating one.
