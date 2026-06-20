defmodule Mix.Tasks.SkillKit.Demo do
  @moduledoc """
  Smoke-test the full SkillKit agent loop against the Anthropic API.

      mix skill_kit.demo "What is 2 + 2?"
  """

  use Mix.Task

  alias SkillKit.Event.Delta
  alias SkillKit.Event.Error, as: EventError
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

    agent_dir = Path.join(System.get_env("SKILL_KIT_AGENTS", "examples/agents"), "neve")
    skills_dir = System.get_env("SKILL_KIT_SKILLS", "examples/skills")

    {:ok, agent} =
      SkillKit.start_agent(agent_dir,
        tools: [{SkillKit.Tools.Shell, []}],
        skills: [{SkillKit.Kit.Local, dir: skills_dir}],
        caller: self()
      )

    Mix.shell().info("Sent: #{prompt}")
    :ok = SkillKit.send_message(agent, prompt)

    agent.name
    |> SkillKit.Stream.stream(timeout: @idle_timeout)
    |> Stream.each(&print/1)
    |> Enum.reduce(:timeout, fn event, _ -> event end)
    |> report()

    SkillKit.stop_agent(agent)
  end

  defp print(%Delta{text: text}), do: IO.write(text)
  defp print(_event), do: :ok

  defp report(%AssistantMessage{}), do: IO.puts("--- Turn complete ---")
  defp report(%EventError{reason: reason}), do: Mix.shell().error("\nError: #{inspect(reason)}")
  defp report(:timeout), do: :ok
end
