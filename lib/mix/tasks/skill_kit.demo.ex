defmodule Mix.Tasks.SkillKit.Demo do
  @moduledoc """
  Smoke-test the full SkillKit agent loop against the Anthropic API.

      mix skill_kit.demo "What is 2 + 2?"
  """

  use Mix.Task

  alias SkillKit.Agent.Definition
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Error
  alias SkillKit.Types.AssistantMessage

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

    agent_md = Path.join(System.get_env("SKILL_KIT_AGENTS", "examples/agents"), "neve/AGENT.md")
    {:ok, definition} = Definition.parse(agent_md)

    skills_dir = System.get_env("SKILL_KIT_SKILLS", "examples/skills")

    {:ok, agent} =
      SkillKit.start_agent(definition,
        skills: [{SkillKit.Backend.Filesystem, dirs: [skills_dir]}],
        caller: self()
      )

    Mix.shell().info("Sent: #{prompt}")
    :ok = SkillKit.send_message(agent, prompt)

    receive_events(definition.name)

    SkillKit.stop_agent(agent)
  end

  defp receive_events(agent_name) do
    receive do
      %Delta{agent: ^agent_name, text: text} ->
        IO.write(text)
        receive_events(agent_name)

      %AssistantMessage{agent: ^agent_name} ->
        IO.puts("\n--- Turn complete ---")
        receive_events(agent_name)

      %Error{agent: ^agent_name, reason: reason} ->
        Mix.shell().error("\nError: #{inspect(reason)}")

      _other ->
        receive_events(agent_name)
    after
      @idle_timeout -> :ok
    end
  end
end
