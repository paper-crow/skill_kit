defmodule SkillKit.Web.BuilderKit do
  @moduledoc """
  Kit provider for build pipeline operations.

  Manages the document-to-code graph and orchestrates the build
  pipeline: change detection, requirements generation, planning,
  and code generation.
  """

  use SkillKit.Kit, name: "build"

  alias SkillKit.ToolExecution
  alias SkillKit.Web.BuilderKit.Tool

  @impl SkillKit.Tool
  def execute(%ToolExecution{} = execution) do
    Tool.execute(execution)
  end
end
