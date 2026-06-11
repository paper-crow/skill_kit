defmodule SkillKit.Eval.Case do
  @moduledoc """
  Turns a directory of `EVAL.md` files into ExUnit tests.

  `use SkillKit.Eval.Case` discovers every eval case under `:dir` at compile
  time and defines one test per case. Each generated test runs the case
  through `SkillKit.Eval.Runner` and asserts that all of its checks pass; a
  failure renders the failing checks and transcript via
  `SkillKit.Eval.Result.failure_message/1`.

      defmodule MyApp.SkillEvalTest do
        use SkillKit.Eval.Case, dir: "test/evals"
      end

  Test names are qualified by the eval file's directory (e.g.
  `"greeter: greets the user by name"`) so cases from different files don't
  collide.

  Generated tests are tagged `:eval`. Because they drive a real agent (and an
  LLM judge), exclude them from the default suite and opt in explicitly:

      # test_helper.exs
      ExUnit.start(exclude: [:eval])

      # run the skill evals against a configured provider
      LLM_PROVIDER=anthropic mix test --include eval

  ## Options

    * `:dir` (required) — directory to scan for `EVAL.md` / `*.eval.md` files,
      relative to the project root.
    * `:run` — keyword options forwarded to `SkillKit.Eval.Runner.run/2`
      (e.g. `[timeout: 60_000, judge: false]`).
  """

  alias SkillKit.Eval

  @doc false
  defmacro __using__(opts) do
    dir = Keyword.fetch!(opts, :dir)
    run_opts = Keyword.get(opts, :run, [])
    tests = Enum.map(Eval.load_dir!(dir), &eval_test(&1, run_opts))

    quote do
      use ExUnit.Case, async: false

      alias SkillKit.Eval.Result
      alias SkillKit.Eval.Runner

      unquote_splicing(tests)
    end
  end

  defp eval_test(eval, run_opts) do
    quote do
      @tag :eval
      test unquote(test_name(eval)) do
        result = Runner.run(unquote(Macro.escape(eval)), unquote(Macro.escape(run_opts)))
        assert Result.passed?(result), Result.failure_message(result)
      end
    end
  end

  defp test_name(%{location: nil, name: name}), do: "eval: #{name}"

  defp test_name(%{location: location, name: name}) do
    "#{Path.basename(Path.dirname(location))}: #{name}"
  end
end
