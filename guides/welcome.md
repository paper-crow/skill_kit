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

### **Robust Architecture**
Each agent runs as an isolated OTP supervision tree with its own Registry, ensuring fault tolerance and process isolation.

### **Flexible Tool System**
- Load skills from filesystem, module-backed kits, or in-memory providers
- Compile-time skill parsing with automatic recompilation on changes
- Execute tools with proper authorization
- Support for hooks at execution boundaries
- Extensible through behavior-based providers

### **Intelligent Agent Lifecycle**
- Source-driven or definition-driven agent startup
- Buffered message processing with size and time thresholds
- Synchronous LLM loops with streaming responses
- Clean shutdown and resource management

### **Streaming & Events**
Real-time streaming of LLM responses with structured events (`%Event.Delta{}`, `%Event.ToolCallStart{}`, etc.) back to caller processes.

### **Subagent Delegation**
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
# 1. Start an agent — from a module-backed kit, path, or definition
{:ok, agent} = SkillKit.start_agent(MyApp.AssistantKit, caller: self())

# 2. Send messages
:ok = SkillKit.send_message(agent, "Hello, how can you help me?")

# 3. Clean up
:ok = SkillKit.stop_agent(agent)
```

`start_agent/2` accepts multiple forms for the first argument:

```elixir
# Module-backed kit — skills and AGENT.md compiled into the module
SkillKit.start_agent(MyApp.AssistantKit)

# Filesystem path — loads AGENT.md and skills/ from disk at runtime
SkillKit.start_agent("priv/agents/assistant")

# With options — skills, scope, runtime, conversation store
SkillKit.start_agent(MyApp.AssistantKit,
  skills: [{MyApp.ExtraKit, []}],
  scope: %MyApp.Scope{user: current_user}
)
```

When starting from a kit (module or path), the kit's skills are automatically
included in the agent's tool pool. The `%SkillKit.Agent{}` struct carries all
configuration and flows through the entire supervision tree. See the
[Architecture](architecture.md) and [Providers](providers.md) guides for details.

This framework enables building sophisticated AI agents that are both powerful and reliable, leveraging Elixir's strengths in concurrent, fault-tolerant systems.