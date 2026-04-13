defmodule SkillKit.Web.OnboardingKit do
  @moduledoc """
  Kit provider for onboarding operations.

  Loads the onboarding skill and dispatches tool execution
  to `SkillKit.Web.OnboardingKit.Tool`.
  """

  use SkillKit.Kit, name: "onboard"

  alias SkillKit.ToolExecution
  alias SkillKit.Web.OnboardingKit.Tool

  @impl SkillKit.Tool
  def execute(%ToolExecution{} = execution) do
    Tool.execute(execution)
  end
end
