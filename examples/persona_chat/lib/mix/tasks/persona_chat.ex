defmodule Mix.Tasks.PersonaChat do
  use Mix.Task

  @shortdoc "Run the PersonaChat example app"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    PersonaChat.CLI.main(args)
  end
end
