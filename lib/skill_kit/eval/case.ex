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

      # run only the skill evals against a real provider
      ANTHROPIC_API_KEY=... mix test --only eval

  ## Options

    * `:dir` (required) — directory to scan for `EVAL.md` / `*.eval.md` files,
      relative to the project root.
    * `:run` — keyword options forwarded to `SkillKit.Eval.Runner.run/2`
      (e.g. `[timeout: 60_000, judge: false]`).
    * `:storage` — storage provider to use while these eval tests run, default
      `SkillKit.Storage.File`. Eval skills are loaded from real files on disk,
      but the test environment otherwise configures in-memory storage; a
      per-test `setup` swaps the provider in (and restores it after) so
      colocated `SKILL.md` files resolve. Set to `false` to leave the
      configured provider untouched.

  Because the agent and judge call a real provider, pin a provider URI via
  `:run` so eval cases don't fall back to the test mock:

      use SkillKit.Eval.Case,
        dir: "skills",
        run: [
          model: "anthropic:claude-sonnet-4-6",
          judge_model: "anthropic:claude-sonnet-4-6"
        ]
  """

  alias SkillKit.Eval

  @doc false
  defmacro __using__(opts) do
    dir = Keyword.fetch!(opts, :dir)
    run_opts = Keyword.get(opts, :run, [])
    storage = Keyword.get(opts, :storage, SkillKit.Storage.File)
    tests = Enum.map(Eval.load_dir!(dir), &eval_test(&1, run_opts))

    quote do
      use ExUnit.Case, async: false

      alias SkillKit.Eval.Result
      alias SkillKit.Eval.Runner

      setup context do
        SkillKit.Eval.Case.put_storage(context, unquote(storage))
      end

      unquote_splicing(tests)
    end
  end

  @doc false
  # Swaps the storage provider for an `:eval`-tagged test so disk-backed skill
  # files resolve, restoring the prior configuration afterward. The eval-tag
  # match keeps this inert for any non-eval test sharing the module.
  def put_storage(_context, false), do: :ok

  def put_storage(%{eval: true}, provider) do
    previous = Application.get_env(:skill_kit, SkillKit.Storage)
    Application.put_env(:skill_kit, SkillKit.Storage, provider: provider)
    ExUnit.Callbacks.on_exit(fn -> restore_storage(previous) end)
    :ok
  end

  def put_storage(_context, _provider), do: :ok

  defp restore_storage(nil), do: Application.delete_env(:skill_kit, SkillKit.Storage)
  defp restore_storage(previous), do: Application.put_env(:skill_kit, SkillKit.Storage, previous)

  defp eval_test(eval, run_opts) do
    quote do
      @tag :eval
      test unquote(test_name(eval)) do
        result = Runner.run(unquote(Macro.escape(eval)), unquote(Macro.escape(run_opts)))
        SkillKit.Eval.Case.emit_warnings(unquote(test_name(eval)), result)
        assert Result.passed?(result), Result.failure_message(result)
      end
    end
  end

  @doc false
  # Surfaces non-fatal judge warnings on a passing eval — ExUnit prints nothing
  # for a pass, so a warning would otherwise be invisible.
  def emit_warnings(name, result) do
    for warning <- SkillKit.Eval.Result.warnings(result) do
      IO.puts(:stderr, "  ⚠ #{name}: #{warning}")
    end

    :ok
  end

  defp test_name(%{location: nil, name: name}), do: "eval: #{name}"

  defp test_name(%{location: location, name: name}) do
    "#{Path.basename(Path.dirname(location))}: #{name}"
  end
end
