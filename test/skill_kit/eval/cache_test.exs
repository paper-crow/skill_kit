defmodule SkillKit.Eval.CacheTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval
  alias SkillKit.Eval.Cache

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "eval_cache_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp tmp_file, do: Path.join(tmp_dir(), "cache.bin")

  describe "fingerprint/2" do
    test "is stable for the same eval and opts" do
      eval = %Eval{name: "n", prompt: "p", rubric: "r"}
      assert Cache.fingerprint(eval) == Cache.fingerprint(eval)
    end

    test "changes when the prompt or rubric changes" do
      base = %Eval{name: "n", prompt: "p", rubric: "r"}
      refute Cache.fingerprint(base) == Cache.fingerprint(%{base | prompt: "p2"})
      refute Cache.fingerprint(base) == Cache.fingerprint(%{base | rubric: "r2"})
    end

    test "changes when the model option changes" do
      eval = %Eval{name: "n", prompt: "p", rubric: "r"}
      refute Cache.fingerprint(eval, model: "a") == Cache.fingerprint(eval, model: "b")
    end

    test "ignores the :cache option itself" do
      eval = %Eval{name: "n", prompt: "p", rubric: "r"}
      assert Cache.fingerprint(eval, cache: "x") == Cache.fingerprint(eval, [])
    end

    test "reflects the skill source content" do
      skill = Path.join(tmp_dir(), "SKILL.md")
      File.write!(skill, "version one")
      eval = %Eval{name: "n", prompt: "p", rubric: "r", skills: [skill]}

      before = Cache.fingerprint(eval)
      File.write!(skill, "version two")

      refute before == Cache.fingerprint(eval)
    end

    test "incorporates the subject module's compiled hash" do
      base = %Eval{name: "n", prompt: "p", rubric: "r"}
      anchored = %{base | module: SkillKit.Tools.Shell}

      refute Cache.fingerprint(base) == Cache.fingerprint(anchored)
    end

    test "distinguishes module providers by code, not just name" do
      shell = %Eval{name: "n", prompt: "p", rubric: "r", tools: [SkillKit.Tools.Shell]}
      other = %{shell | tools: [SkillKit.Eval.SkillFile]}

      # different modules → different fingerprints (each folds in its own MD5)
      refute Cache.fingerprint(shell) == Cache.fingerprint(other)
      # and a module provider is hashed by its compiled code, not the bare name
      named = %{shell | tools: ["SkillKit.Tools.Shell"]}
      refute Cache.fingerprint(shell) == Cache.fingerprint(named)
    end

    test "incorporates the target agent directory's contents" do
      dir = tmp_dir()
      File.write!(Path.join(dir, "AGENT.md"), "---\nname: a\n---\nv1")
      eval = %Eval{name: "n", prompt: "p", rubric: "r", agent: dir}

      before = Cache.fingerprint(eval)
      # an agent-anchored eval differs from one with no agent
      refute before == Cache.fingerprint(%{eval | agent: nil})

      # and re-runs when the agent directory changes
      File.write!(Path.join(dir, "AGENT.md"), "---\nname: a\n---\nv2")
      refute before == Cache.fingerprint(eval)
    end
  end

  describe "get/2 and put/3" do
    test "records a fingerprint as a pass and reads it back" do
      path = tmp_file()
      assert Cache.get(path, "fp") == :miss
      assert Cache.put(path, "fp", "a case") == :ok
      assert Cache.get(path, "fp") == :pass
    end

    test "a missing cache file reads as a miss" do
      assert Cache.get(tmp_file(), "fp") == :miss
    end

    test "a corrupt cache file is treated as empty" do
      path = tmp_file()
      File.write!(path, "not a term")
      assert Cache.get(path, "fp") == :miss
    end
  end

  describe "default_path/0" do
    test "lives under the Mix build directory" do
      assert Cache.default_path() =~ "_build"
    end
  end
end
