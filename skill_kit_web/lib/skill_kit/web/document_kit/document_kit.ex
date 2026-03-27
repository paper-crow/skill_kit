defmodule SkillKit.Web.DocumentKit do
  @moduledoc """
  Kit provider for document operations.

  Loads seven document skills from SKILL.md files and dispatches
  execution to `SkillKit.Web.DocumentKit.Tool`.
  """

  use SkillKit.Kit, name: "docs"

  alias SkillKit.ToolExecution
  alias SkillKit.Web.DocumentKit.Tool

  @impl SkillKit.Tool
  def execute(%ToolExecution{} = execution) do
    Tool.execute(execution)
  end
end
