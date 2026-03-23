---
name: project-a
description: Manages project A. Use when the user asks about project A.
capabilities: Read, Grep, Glob, Bash
model: claude-sonnet-4-6
metadata:
  workspace: ~/.agents/project-a
  max_agent_depth: "2"
  mailbox_max_messages: "5"
  mailbox_flush_interval: "200"
---
You are the project A manager. Report results clearly.
