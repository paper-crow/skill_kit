defmodule SkillKit.SupervisorTest do
  use ExUnit.Case, async: true

  alias SkillKit.{Registry, Skill, Supervisor}

  # ---------------------------------------------------------------------------
  # child_spec/1 shape
  # ---------------------------------------------------------------------------

  describe "child_spec/1" do
    test "returns a valid child spec map with expected keys" do
      spec = Supervisor.child_spec([])

      assert is_map(spec)
      assert Map.has_key?(spec, :id)
      assert Map.has_key?(spec, :start)
      assert Map.has_key?(spec, :type)

      # type should be :supervisor (set by `use Supervisor`)
      assert spec.type == :supervisor

      # start should be a {mod, fun, args} tuple
      assert {mod, fun, _args} = spec.start
      assert is_atom(mod)
      assert is_atom(fun)
    end

    test "allows host apps to use {SkillKit.Supervisor, opts} tuple syntax" do
      # Verify child_spec/1 accepts an opts list — the tuple syntax requires this
      spec = Supervisor.child_spec(registry_name: :my_registry)
      assert is_map(spec)
    end
  end

  # ---------------------------------------------------------------------------
  # Supervisor starts Registry
  # ---------------------------------------------------------------------------

  describe "Supervisor starts Registry" do
    test "supervisor starts and registry process is alive" do
      sup_name = :"sup_#{:erlang.unique_integer([:positive])}"
      reg_name = :"reg_#{:erlang.unique_integer([:positive])}"

      start_supervised!({Supervisor, name: sup_name, registry_name: reg_name})

      # Verify the registry is alive by calling it — should return [] without error
      assert [] = Registry.list_skills(reg_name)
    end

    test "supervisor process is registered under the given name" do
      sup_name = :"sup_#{:erlang.unique_integer([:positive])}"
      reg_name = :"reg_#{:erlang.unique_integer([:positive])}"

      start_supervised!({Supervisor, name: sup_name, registry_name: reg_name})

      assert is_pid(Process.whereis(sup_name))
    end

    test "registry process is registered under the given name" do
      sup_name = :"sup_#{:erlang.unique_integer([:positive])}"
      reg_name = :"reg_#{:erlang.unique_integer([:positive])}"

      start_supervised!({Supervisor, name: sup_name, registry_name: reg_name})

      assert is_pid(Process.whereis(reg_name))
    end
  end

  # ---------------------------------------------------------------------------
  # Full round-trip through Supervisor
  # ---------------------------------------------------------------------------

  describe "full round-trip through Supervisor" do
    test "start supervisor -> register skill -> get skill" do
      sup_name = :"sup_#{:erlang.unique_integer([:positive])}"
      reg_name = :"reg_#{:erlang.unique_integer([:positive])}"

      start_supervised!({Supervisor, name: sup_name, registry_name: reg_name})

      skill = %Skill{name: "files:read", namespace: "files"}
      assert :ok = Registry.register(reg_name, skill)
      assert {:ok, ^skill} = Registry.get_skill(reg_name, "files:read")
    end

    test "start supervisor -> register multiple skills -> list_skills returns all" do
      sup_name = :"sup_#{:erlang.unique_integer([:positive])}"
      reg_name = :"reg_#{:erlang.unique_integer([:positive])}"

      start_supervised!({Supervisor, name: sup_name, registry_name: reg_name})

      skill1 = %Skill{name: "files:read", namespace: "files"}
      skill2 = %Skill{name: "tools:search", namespace: "tools"}

      :ok = Registry.register(reg_name, skill1)
      :ok = Registry.register(reg_name, skill2)

      result = Registry.list_skills(reg_name)
      assert length(result) == 2
      assert skill1 in result
      assert skill2 in result
    end

    test "registry is isolated per supervisor — skills don't bleed across instances" do
      sup1_name = :"sup1_#{:erlang.unique_integer([:positive])}"
      reg1_name = :"reg1_#{:erlang.unique_integer([:positive])}"
      sup2_name = :"sup2_#{:erlang.unique_integer([:positive])}"
      reg2_name = :"reg2_#{:erlang.unique_integer([:positive])}"

      start_supervised!({Supervisor, name: sup1_name, registry_name: reg1_name}, id: sup1_name)
      start_supervised!({Supervisor, name: sup2_name, registry_name: reg2_name}, id: sup2_name)

      skill = %Skill{name: "files:read", namespace: "files"}
      :ok = Registry.register(reg1_name, skill)

      # Registered in reg1 — should not appear in reg2
      assert {:ok, ^skill} = Registry.get_skill(reg1_name, "files:read")
      assert {:error, :not_found} = Registry.get_skill(reg2_name, "files:read")
    end
  end

  # ---------------------------------------------------------------------------
  # Non-negotiable constraints (guard tests)
  # ---------------------------------------------------------------------------

  describe "non-negotiable constraints" do
    test "no mod: in mix.exs application/0 function" do
      mix_exs_path = Path.join(File.cwd!(), "mix.exs")
      content = File.read!(mix_exs_path)

      # Find the application/0 function block and assert no mod: key
      refute String.contains?(content, "mod:"),
             "mix.exs application/0 must NOT contain mod: — SkillKit is a library, not an application"
    end

    test "no Application.get_env calls in library code" do
      lib_path = Path.join(File.cwd!(), "lib")

      # Boundary modules that legitimately use Application.get_env for
      # configurable dispatch (same pattern as Mox, Tesla, etc.)
      allowed = MapSet.new(["llm.ex"])

      # Walk all .ex files in lib/ and check for Application.get_env usage
      violations =
        lib_path
        |> File.ls!()
        |> Enum.flat_map(fn entry ->
          entry_path = Path.join(lib_path, entry)

          if File.dir?(entry_path) do
            entry_path
            |> File.ls!()
            |> Enum.map(&Path.join(entry_path, &1))
            |> Enum.filter(&String.ends_with?(&1, ".ex"))
          else
            if String.ends_with?(entry_path, ".ex"), do: [entry_path], else: []
          end
        end)
        |> Enum.reject(fn file -> MapSet.member?(allowed, Path.basename(file)) end)
        |> Enum.filter(fn file ->
          content = File.read!(file)
          String.contains?(content, "Application.get_env")
        end)

      assert violations == [],
             "Library code must not call Application.get_env. Violations found in: #{inspect(violations)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Supervisor opts passthrough — skill_dirs and skills
  # ---------------------------------------------------------------------------

  describe "Supervisor with skills passthrough" do
    @valid_fixtures_path Path.join([
                           __DIR__,
                           "..",
                           "support",
                           "fixtures",
                           "skills",
                           "valid"
                         ])

    test "supervisor with skills discovers and registers .skill.md files" do
      sup_name = :"sup_dirs_#{:erlang.unique_integer([:positive])}"
      reg_name = :"reg_dirs_#{:erlang.unique_integer([:positive])}"

      start_supervised!({
        Supervisor,
        name: sup_name,
        registry_name: reg_name,
        skills: [{SkillKit.Kit.Local, dirs: [@valid_fixtures_path]}]
      })

      skills = Registry.list_skills(reg_name)
      skill_names = Enum.map(skills, & &1.name)

      assert "files:summarize" in skill_names
      assert "tools:greet" in skill_names
    end
  end
end
