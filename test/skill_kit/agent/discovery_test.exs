defmodule SkillKit.Agent.DiscoveryTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.Discovery

  @fixtures_path Path.join([__DIR__, "..", "..", "support", "fixtures", "agents"])

  describe "discover/1" do
    test "discovers AGENT.md files from a directory" do
      dirs = [Path.join(@fixtures_path, "valid")]
      assert {:ok, definitions} = Discovery.discover(dirs)

      names = Enum.map(definitions, & &1.name)
      assert "project-a" in names
      assert "simple" in names
    end

    test "returns empty list for directory with no AGENT.md files" do
      dir = System.tmp_dir!()
      assert {:ok, []} = Discovery.discover([dir])
    end

    test "skips invalid AGENT.md files without crashing" do
      dirs = [
        Path.join(@fixtures_path, "valid"),
        Path.join(@fixtures_path, "invalid")
      ]

      assert {:ok, definitions} = Discovery.discover(dirs)
      names = Enum.map(definitions, & &1.name)
      assert "project-a" in names
      refute Enum.any?(definitions, &is_nil(&1.name))
    end

    test "first directory wins on name conflicts" do
      tmp = Path.join(System.tmp_dir!(), "discovery_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "simple"))

      File.write!(Path.join([tmp, "simple", "AGENT.md"]), """
      ---
      name: simple
      description: Override version.
      ---
      Override body.
      """)

      dirs = [tmp, Path.join(@fixtures_path, "valid")]
      assert {:ok, definitions} = Discovery.discover(dirs)

      simple = Enum.find(definitions, &(&1.name == "simple"))
      assert simple.description == "Override version."

      File.rm_rf!(tmp)
    end

    test "ignores nonexistent directories" do
      dirs = ["/nonexistent/path", Path.join(@fixtures_path, "valid")]
      assert {:ok, definitions} = Discovery.discover(dirs)
      assert definitions != []
    end
  end
end
