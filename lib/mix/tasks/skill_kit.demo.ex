defmodule Mix.Tasks.SkillKit.Demo do
  @moduledoc """
  Smoke-test the full SkillKit agent loop against the Anthropic API.

      mix skill_kit.demo "What is 2 + 2?"
  """

  use Mix.Task

  alias SkillKit.Agent.Definition

  @shortdoc "Run a single-turn agent conversation"
  @idle_timeout 10_000

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

    agent_md = Path.join(System.get_env("SKILL_KIT_AGENTS", "examples/agents"), "neve/AGENT.md")
    {:ok, definition} = Definition.parse(agent_md)
    definition = %{definition | workspace: File.cwd!()}

    skills_dir = System.get_env("SKILL_KIT_SKILLS", "examples/skills")

    {:ok, agent} = SkillKit.start_agent(definition,
      sources: [{SkillKit.Backend.Filesystem, dirs: [skills_dir]}],
      provider: {SkillKit.LLM.Anthropic, [api_key: api_key]},
      caller: self()
    )

    Mix.shell().info("Sent: #{prompt}")
    :ok = SkillKit.send_message(agent, prompt)

    receive_events(definition.name)

    SkillKit.stop_agent(agent)
  end

  defp receive_events(agent_name) do
    receive do
      {:skill_kit, ^agent_name, event} ->
        handle_event(event)
        receive_events(agent_name)
    after
      @idle_timeout -> :ok
    end
  end

  defp handle_event({:delta, text}), do: IO.write(text)
  defp handle_event({:response, _text}), do: IO.puts("\n--- Turn complete ---")
  defp handle_event({:error, reason}), do: Mix.shell().error("\nError: #{inspect(reason)}")
  defp handle_event(_other), do: :ok
end
