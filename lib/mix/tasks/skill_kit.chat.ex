defmodule Mix.Tasks.SkillKit.Chat do
  @moduledoc """
  Interactive chat session with a SkillKit agent.

      mix skill_kit.chat
  """

  use Mix.Task

  alias SkillKit.Agent.Definition

  @shortdoc "Start an interactive agent chat session"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    api_key = System.get_env("ANTHROPIC_API_KEY")

    unless api_key do
      Mix.shell().error("Set ANTHROPIC_API_KEY environment variable")
      exit({:shutdown, 1})
    end

    agent_md = Path.join(:code.priv_dir(:skill_kit), "sample_agent/AGENT.md")
    {:ok, definition} = Definition.parse(agent_md)

    skills_dir = Path.join(:code.priv_dir(:skill_kit), "skills")

    {:ok, agent} = SkillKit.start_agent(definition,
      sources: [{SkillKit.Backend.Filesystem, dirs: [skills_dir]}],
      provider: {SkillKit.LLM.Anthropic, [api_key: api_key]},
      caller: self()
    )

    IO.puts("SkillKit Chat — type 'exit' to quit\n")

    chat_loop(agent, definition.name)

    SkillKit.stop_agent(agent)
  end

  defp chat_loop(agent, agent_name) do
    case IO.gets("you> ") do
      :eof ->
        :ok

      input ->
        prompt = String.trim(input)

        cond do
          prompt == "exit" ->
            IO.puts("Goodbye.")

          prompt == "" ->
            chat_loop(agent, agent_name)

          true ->
            :ok = SkillKit.send_message(agent, prompt)
            receive_response(agent_name)
            chat_loop(agent, agent_name)
        end
    end
  end

  defp receive_response(agent_name) do
    receive do
      {:skill_kit, ^agent_name, {:delta, text}} ->
        IO.write(text)
        receive_response(agent_name)

      {:skill_kit, ^agent_name, {:tool_call, name, input}} ->
        IO.puts(IO.ANSI.format([:faint, "  ↳ #{name}(#{format_input(name, input)})"]))
        receive_response(agent_name)

      {:skill_kit, ^agent_name, {:tool_result, _name, _content, _is_error}} ->
        receive_response(agent_name)

      {:skill_kit, ^agent_name, {:response, _text}} ->
        IO.puts("\n")
        wait_for_follow_up(agent_name)

      {:skill_kit, ^agent_name, {:error, reason}} ->
        IO.puts("\n[error] #{inspect(reason)}\n")
    after
      120_000 ->
        IO.puts("\n[timeout]\n")
    end
  end

  defp format_input("bash", %{"command" => cmd}), do: cmd
  defp format_input("activate_skill", %{"name" => name}), do: name
  defp format_input(_name, input) when map_size(input) == 0, do: ""
  defp format_input(_name, input), do: inspect(input, limit: 3)

  defp wait_for_follow_up(agent_name) do
    receive do
      {:skill_kit, ^agent_name, {:delta, _text}} = msg ->
        IO.puts("--- subagent result arrived ---")
        send(self(), msg)
        receive_response(agent_name)
    after
      5_000 ->
        :ok
    end
  end
end
