---
name: ask
description: Ask the user a question through the onboarding UI
metadata:
  input_schema:
    type: object
    properties:
      question:
        type: string
        description: The question text to display
      subtext:
        type: string
        description: Brief helper text shown below the question to guide the user
      placeholder:
        type: string
        description: Example text shown in the input field before the user types
    required:
      - question
---
Send a question to the user through the onboarding interface. The question will be displayed in a focused, single-question format.

Always provide all three fields:
- `question` — the question text
- `subtext` — brief guidance below the question
- `placeholder` — an example answer in the input field
