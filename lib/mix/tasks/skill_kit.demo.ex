defmodule Mix.Tasks.SkillKit.Demo do
  @moduledoc """
  Smoke-test the full SkillKit agent loop against the Anthropic API.

      mix skill_kit.demo "What is 2 + 2?"
  """

  use Mix.Task

  alias SkillKit.Agent
  alias SkillKit.Agent.Definition
  alias SkillKit.LLM.Message

  @shortdoc "Run a single-turn agent conversation"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    prompt = Enum.join(args, " ")

    if prompt == "" do
      Mix.shell().error("Usage: mix skill_kit.demo \"your prompt here\"")
      exit({:shutdown, 1})
    end

    api_key = System.get_env("ANTHROPIC_API_KEY")

    unless api_key do
      Mix.shell().error("Set ANTHROPIC_API_KEY environment variable")
      exit({:shutdown, 1})
    end

    attach_telemetry()

    agent_md = Path.join(:code.priv_dir(:skill_kit), "sample_agent/AGENT.md")
    {:ok, definition} = Definition.parse(agent_md)

    registry_name = SkillKit.Demo.AgentRegistry
    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

    {:ok, _pid} = Agent.start_link(%{
      agent_name: "sample-agent",
      definition: definition,
      depth: 0,
      parent_name: nil,
      scope: nil,
      sources: [],
      registry: registry_name,
      provider: {SkillKit.LLM.Anthropic, [api_key: api_key]}
    })

    [{mailbox_pid, _}] = Registry.lookup(registry_name, {"sample-agent", :mailbox})
    GenServer.cast(mailbox_pid, {:message, %Message.User{content: prompt}})

    Mix.shell().info("Sent: #{prompt}")
    Mix.shell().info("Waiting for agent response...\n")

    wait_for_turn_end()
  end

  def handle_telemetry([:skill_kit, :agent, :response], _, metadata, _) do
    case metadata.response do
      %Message.Assistant{content: content} when is_binary(content) ->
        Mix.shell().info("\nAgent: #{content}")

      _ ->
        :ok
    end
  end

  def handle_telemetry([:skill_kit, :agent, :tool_call], _, metadata, _) do
    tc = metadata.tool_call
    Mix.shell().info("[tool_call] #{tc.name}(#{inspect(tc.input)})")
  end

  def handle_telemetry([:skill_kit, :agent, :tool_result], _, metadata, _) do
    result = metadata.result
    label = if result.is_error, do: "[tool_error]", else: "[tool_result]"
    truncated = String.slice(result.content, 0, 500)
    Mix.shell().info("#{label} #{truncated}")
  end

  def handle_telemetry([:skill_kit, :agent, :turn_end], _, _, _) do
    send(Process.whereis(:demo_waiter), :turn_ended)
  end

  defp attach_telemetry do
    :telemetry.attach_many(
      "demo-telemetry",
      [
        [:skill_kit, :agent, :response],
        [:skill_kit, :agent, :tool_call],
        [:skill_kit, :agent, :tool_result],
        [:skill_kit, :agent, :turn_end]
      ],
      &__MODULE__.handle_telemetry/4,
      nil
    )
  end

  defp wait_for_turn_end do
    Process.register(self(), :demo_waiter)

    receive do
      :turn_ended ->
        Mix.shell().info("\n--- Turn complete ---")
    after
      60_000 ->
        Mix.shell().error("Timed out waiting for agent response")
    end
  end
end
