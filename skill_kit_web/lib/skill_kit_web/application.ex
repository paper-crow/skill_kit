defmodule SkillKitWeb.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = dev_children()

    opts = [strategy: :one_for_one, name: SkillKitWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp dev_children do
    if Application.get_env(:skill_kit_web, SkillKit.Web.DevEndpoint) do
      [SkillKit.Web.DevEndpoint]
    else
      []
    end
  end
end
