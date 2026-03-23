defmodule Mix.Tasks.SkillKit.Demo do
  @moduledoc """
  Smoke-test the full SkillKit agent loop against the Anthropic API.

      mix skill_kit.demo "What is 2 + 2?"
  """

  use Mix.Task

  alias SkillKit.Agent.Definition

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

    agent_md = System.get_env("SKILL_KIT_AGENTS", "examples/agents") |> Path.join("neve/AGENT.md")
    {:ok, definition} = Definition.parse(agent_md)

    skills_dir = System.get_env("SKILL_KIT_SKILLS", "examples/skills")

    {:ok, agent} = SkillKit.start_agent(definition,
      sources: [{SkillKit.Backend.Filesystem, dirs: [skills_dir]}],
      provider: {SkillKit.LLM.Anthropic, [api_key: api_key]},
      caller: self()
    )

    Mix.shell().info("Sent: #{prompt}")
    :ok = SkillKit.send_message(agent, prompt)

    receive_loop(definition.name)

    SkillKit.stop_agent(agent)
  end

  defp receive_loop(agent_name) do
    receive do
      {:skill_kit, ^agent_name, {:delta, text}} ->
        IO.write(text)
        receive_loop(agent_name)

      {:skill_kit, ^agent_name, {:response, _text}} ->
        IO.puts("")
        Mix.shell().info("--- Turn complete ---")
        # Wait for potential follow-up turns (e.g. subagent results)
        wait_for_follow_up(agent_name)

      {:skill_kit, ^agent_name, {:error, reason}} ->
        Mix.shell().error("Error: #{inspect(reason)}")
    after
      120_000 ->
        Mix.shell().error("Timed out waiting for agent response")
    end
  end

  defp wait_for_follow_up(agent_name) do
    receive do
      {:skill_kit, ^agent_name, {:delta, _text}} = msg ->
        Mix.shell().info("\n--- New turn (subagent result arrived) ---")
        send(self(), msg)
        receive_loop(agent_name)
    after
      30_000 ->
        :ok
    end
  end
end
