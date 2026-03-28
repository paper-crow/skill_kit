# Welcome to SkillKit

SkillKit is an **Elixir framework for building LLM agent systems** that combines the power of large language models with robust, fault-tolerant architecture using OTP (Open Telecom Platform) principles.

## What We're Building

SkillKit creates intelligent agents that can:

- **Process messages asynchronously** through a buffered mailbox system
- **Execute tools and skills** with proper authorization and scope management
- **Delegate work to subagents** for complex, multi-step tasks
- **Stream real-time responses** back to caller processes
- **Recover gracefully** from failures using Elixir's supervision trees

## Key Features

### 🏗️ **Robust Architecture**
Each agent runs as an isolated OTP supervision tree with its own Registry, ensuring fault tolerance and process isolation.

### 🔧 **Flexible Tool System**
- Load skills from filesystem or in-memory providers
- Execute tools with proper authorization
- Support for hooks at execution boundaries
- Extensible through behavior-based providers

### 🤖 **Intelligent Agent Lifecycle**
- Source-driven or definition-driven agent startup
- Buffered message processing with size and time thresholds
- Synchronous LLM loops with streaming responses
- Clean shutdown and resource management

### 🌊 **Streaming & Events**
Real-time streaming of LLM responses with structured events (`%Event.Delta{}`, `%Event.ToolCallStart{}`, etc.) back to caller processes.

### 🎯 **Subagent Delegation**
Agents can spawn child agents for specialized tasks, with depth controls and parent-child communication through Registry lookups.

## Core Components

- **Agent.Server**: Drives the LLM loop and tool execution
- **Agent.Mailbox**: Buffers and batches incoming messages
- **Catalog**: Aggregates skills from providers and manages tool definitions
- **Registry**: Process discovery within each agent's supervision tree
- **SubagentSupervisor**: Dynamic supervision of child agents

## Getting Started

SkillKit follows a simple three-step pattern:

```elixir
# 1. Start an agent
{:ok, agent} = SkillKit.start_agent(
  skills: [{SkillKit.Kit.Local, dir: ".skills"}],
  caller: self(),
  scope: my_scope
)

# 2. Send messages
:ok = SkillKit.send_message(agent, "Hello, how can you help me?")

# 3. Clean up
:ok = SkillKit.stop_agent(agent)
```

This framework enables building sophisticated AI agents that are both powerful and reliable, leveraging Elixir's strengths in concurrent, fault-tolerant systems.