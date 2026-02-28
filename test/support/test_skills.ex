defmodule SkillKit.TestSkills.Echo do
  @moduledoc false
  @behaviour SkillKit.Skill

  @impl SkillKit.Skill
  def name, do: "test:echo"

  @impl SkillKit.Skill
  def description, do: "Echoes input"

  @impl SkillKit.Skill
  def required_scope, do: ["test:read"]

  @impl SkillKit.Skill
  def execute(args, _context), do: {:ok, args}
end
