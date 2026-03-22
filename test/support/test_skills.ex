defmodule SkillKit.TestSkills do
  @moduledoc false

  alias SkillKit.Skill

  def echo_skill do
    %Skill{
      name: "test:echo",
      namespace: "test",
      description: "Echoes input",
      body: "Echo back: $ARGUMENTS",
      required_scope: ["test:read"]
    }
  end

  def no_scope_skill do
    %Skill{
      name: "test:open",
      namespace: "test",
      description: "No scope required",
      body: "Do the thing"
    }
  end
end
