defmodule SkillKit.Eval.CaseExampleTest do
  @moduledoc """
  Exercises the `SkillKit.Eval.Case` macro at compile time. The generated
  tests are tagged `:eval` and excluded from the default suite (see
  `test_helper.exs`); compiling this module proves the macro expands a test
  per fixture eval.
  """
  use SkillKit.Eval.Case, dir: "test/support/fixtures/evals"
end

defmodule SkillKit.Eval.CaseTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval.CaseExampleTest

  test "the macro expands into a compiled ExUnit module" do
    assert Code.ensure_loaded?(CaseExampleTest)
  end

  test "generates one ExUnit test function per fixture eval" do
    Code.ensure_loaded(CaseExampleTest)

    functions = CaseExampleTest.__info__(:functions)

    test_fns =
      Enum.filter(functions, fn {name, arity} ->
        arity == 1 and String.starts_with?(Atom.to_string(name), "test ")
      end)

    assert length(test_fns) == 2
  end
end
