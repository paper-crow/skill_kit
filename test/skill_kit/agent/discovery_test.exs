defmodule SkillKit.Agent.DiscoveryTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.Discovery
  alias SkillKit.Backend.Filesystem

  @fixtures_path Path.join([__DIR__, "..", "..", "support", "fixtures", "agents"])

  describe "discover/1" do
    test "discovers AGENT.md files via filesystem backend" do
      backends = [{Filesystem, dirs: [Path.join(@fixtures_path, "valid")]}]
      assert {:ok, definitions} = Discovery.discover(backends)

      names = Enum.map(definitions, & &1.name)
      assert "project-a" in names
      assert "simple" in names
    end

    test "returns empty list when no agents found" do
      backends = [{Filesystem, dirs: [System.tmp_dir!()]}]
      assert {:ok, []} = Discovery.discover(backends)
    end

    test "skips invalid AGENT.md files without crashing" do
      backends = [{Filesystem, dirs: [
        Path.join(@fixtures_path, "valid"),
        Path.join(@fixtures_path, "invalid")
      ]}]

      assert {:ok, definitions} = Discovery.discover(backends)
      names = Enum.map(definitions, & &1.name)
      assert "project-a" in names
      refute Enum.any?(definitions, &is_nil(&1.name))
    end

    test "first backend wins on name conflicts" do
      tmp = Path.join(System.tmp_dir!(), "discovery_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "simple"))

      File.write!(Path.join([tmp, "simple", "AGENT.md"]), """
      ---
      name: simple
      description: Override version.
      ---
      Override body.
      """)

      backends = [
        {Filesystem, dirs: [tmp]},
        {Filesystem, dirs: [Path.join(@fixtures_path, "valid")]}
      ]
      assert {:ok, definitions} = Discovery.discover(backends)

      simple = Enum.find(definitions, &(&1.name == "simple"))
      assert simple.description == "Override version."

      File.rm_rf!(tmp)
    end
  end
end
