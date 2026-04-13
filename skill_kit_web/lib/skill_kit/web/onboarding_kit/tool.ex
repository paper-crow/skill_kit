defmodule SkillKit.Web.OnboardingKit.Tool do
  @moduledoc """
  Tool implementation for onboarding operations.

  Currently a passthrough — the onboarding skill drives conversation
  via text responses parsed by `SkillKit.Web.Onboarding`. Future
  onboarding-specific tools (e.g., progress tracking, template
  selection) can be dispatched here.
  """

  @behaviour SkillKit.Tool

  @impl true
  def definition do
    %SkillKit.Tool{
      name: "onboard",
      description: "Onboarding operations for new project setup",
      input_schema: %{
        "type" => "object",
        "properties" => %{}
      }
    }
  end

  @impl true
  def execute(%SkillKit.ToolExecution{skill: skill}) do
    {:error, "Unknown onboarding skill: #{skill.name}"}
  end

  @impl true
  def resume(_execution, _state, _decision) do
    {:error, :not_resumable}
  end
end
