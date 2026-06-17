defmodule SkillKit.Eval.CaseExampleTest do
  @moduledoc """
  Exercises the `SkillKit.Eval.Case` macro at compile time. The generated
  tests are tagged `:eval` and excluded from the default suite (see
  `test_helper.exs`); compiling this module proves the macro expands a test
  per fixture eval.
  """
  use SkillKit.Eval.Case, dir: "test/support/fixtures/evals"
end

defmodule SkillKit.Eval.CaseModuleExample do
  @moduledoc """
  Exercises the `modules:` discovery path: pulls `@eval` cases from
  `SkillKit.Test.EvalSubject` via `__skill_evals__/0`.
  """
  use SkillKit.Eval.Case, modules: [SkillKit.Test.EvalSubject]
end

defmodule SkillKit.Eval.CaseTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval.CaseExampleTest
  alias SkillKit.Eval.CaseModuleExample

  defp test_fns(module) do
    Code.ensure_loaded(module)

    module.__info__(:functions)
    |> Enum.filter(fn {name, arity} ->
      arity == 1 and String.starts_with?(Atom.to_string(name), "test ")
    end)
  end

  test "the macro expands into a compiled ExUnit module" do
    assert Code.ensure_loaded?(CaseExampleTest)
  end

  test "generates one ExUnit test function per fixture eval case" do
    assert length(test_fns(CaseExampleTest)) == 3
  end

  test "discovers @eval cases from modules: and names them by module" do
    fns = test_fns(CaseModuleExample)
    assert length(fns) == 1
    assert Enum.any?(fns, fn {name, _} -> Atom.to_string(name) =~ "EvalSubject" end)
  end
end

defmodule SkillKit.Eval.CaseStorageTest do
  # async: false — these mutate the global storage provider configuration.
  use ExUnit.Case, async: false

  test "swaps the storage provider for an eval-tagged context" do
    SkillKit.Eval.Case.put_storage(%{eval: true}, SkillKit.Storage.File)
    assert Application.get_env(:skill_kit, SkillKit.Storage)[:provider] == SkillKit.Storage.File
  end

  test "leaves the provider untouched when storage is false" do
    before = Application.get_env(:skill_kit, SkillKit.Storage)
    assert SkillKit.Eval.Case.put_storage(%{eval: true}, false) == :ok
    assert Application.get_env(:skill_kit, SkillKit.Storage) == before
  end

  test "leaves the provider untouched for a non-eval context" do
    before = Application.get_env(:skill_kit, SkillKit.Storage)
    assert SkillKit.Eval.Case.put_storage(%{}, SkillKit.Storage.File) == :ok
    assert Application.get_env(:skill_kit, SkillKit.Storage) == before
  end
end
