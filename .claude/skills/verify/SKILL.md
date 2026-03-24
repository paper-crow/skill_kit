---
name: verify
description: Run the full precommit validation pipeline (compile, format, credo, test) to verify changes are ready.
---

Run the full SkillKit precommit pipeline and report results:

```bash
mix precommit
```

This runs in order:
1. `mix compile --warnings-as-errors`
2. `mix deps.unlock --unused`
3. `mix format`
4. `mix credo --strict`
5. `mix test`

If any step fails, stop and report the failure with the relevant output. Do not proceed to the next step.

If all steps pass, confirm the changes are ready.
