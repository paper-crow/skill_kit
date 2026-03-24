---
name: delete_persona
description: Delete a persona and all its data
required_scope:
  - persona:delete
---
Delete the persona specified: $ARGUMENTS

Before deleting, confirm with the user. Then use bash to remove:
- The persona directory: `rm -rf personas/$0`
- Any memory files: `rm -rf data/memories/$0`
- Any conversation files matching the persona: `rm -f data/conversations/$0:*`

Report what was removed.
