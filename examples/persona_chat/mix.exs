defmodule PersonaChat.MixProject do
  use Mix.Project

  def project do
    [
      app: :persona_chat,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:skill_kit, path: "../.."},
      {:jason, "~> 1.4"}
    ]
  end
end
