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
