defmodule SkillKit.BackendTest do
  use ExUnit.Case, async: true

  test "Backend module defines load_skills/1 callback" do
    assert {:load_skills, 1} in SkillKit.Backend.behaviour_info(:callbacks)
  end
end
