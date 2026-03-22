defmodule SkillKit.BackendTest do
  use ExUnit.Case, async: true

  test "Backend module defines load_kits/1 callback" do
    assert {:load_kits, 1} in SkillKit.Backend.behaviour_info(:callbacks)
  end
end
