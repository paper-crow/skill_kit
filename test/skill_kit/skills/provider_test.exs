defmodule SkillKit.Skills.ProviderTest do
  use ExUnit.Case, async: true

  test "Provider module defines load_kits/1 callback" do
    assert {:load_kits, 1} in SkillKit.Skills.Provider.behaviour_info(:callbacks)
  end
end
