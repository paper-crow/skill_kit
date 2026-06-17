defmodule SkillKit.Eval.Cache do
  @moduledoc """
  Content-addressed result cache for evals.

  Evals are expensive — each is a real agent run plus an LLM judge call — so the
  harness can skip a case that already passed when nothing in its *scope* has
  changed. Scope is captured as a fingerprint over:

    * the case (name, prompt, rubric, system prompt),
    * the agent and judge models,
    * the source of every skill/tool provider under test (file contents on
      disk, or the module name for module providers),
    * a harness-version token (`@harness_version`) bumped whenever scoring
      semantics change, so upgrades invalidate stale entries.

  Only **passes** are recorded; a fingerprint present in the cache is treated as
  a prior pass and skipped. Failures and unknown fingerprints always run.

  Because LLMs are non-deterministic, a cache hit means "this exact scope
  already passed, trust it" — not a guarantee the run would pass again. That is
  the intended contract for an expensive suite, analogous to a build cache.

  The store is a term file (default under `_build/<env>/`); enable caching with
  `SkillKit.Eval.Runner.run(eval, cache: true)` or `cache: "path/to/file"`.
  """

  alias SkillKit.Eval
  alias SkillKit.Eval.SkillFile

  # Bump when the agent/judge/scoring semantics change so old entries miss.
  @harness_version "1"

  @doc """
  Computes the scope fingerprint for `eval` under `opts` (the same options
  passed to `SkillKit.Eval.Runner.run/2`).
  """
  @spec fingerprint(Eval.t(), keyword()) :: String.t()
  def fingerprint(%Eval{} = eval, opts \\ []) do
    term = {
      @harness_version,
      eval.name,
      eval.prompt,
      eval.rubric,
      eval.system,
      Keyword.get(opts, :model, eval.model),
      Keyword.get(opts, :judge_model, eval.model),
      module_token(eval.module),
      scope_token(eval)
    }

    term
    |> :erlang.term_to_binary()
    |> hash()
  end

  @doc "Default cache path, under the current Mix build directory."
  @spec default_path() :: String.t()
  def default_path do
    Path.join(Mix.Project.build_path(), "skill_kit_eval_cache.bin")
  end

  @doc "`:pass` if `fingerprint` is recorded in the cache at `path`, else `:miss`."
  @spec get(String.t(), String.t()) :: :pass | :miss
  def get(path, fingerprint) do
    if Map.has_key?(load(path), fingerprint), do: :pass, else: :miss
  end

  @doc "Records `fingerprint` as a pass for case `name` in the cache at `path`."
  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(path, fingerprint, name) do
    entry = %{"name" => name, "at" => timestamp()}
    store = Map.put(load(path), fingerprint, entry)
    write(path, store)
  end

  # ---------------------------------------------------------------------------
  # Scope fingerprinting
  # ---------------------------------------------------------------------------

  defp scope_token(eval) do
    eval
    |> providers()
    |> Enum.map_join("|", &provider_source/1)
  end

  defp providers(eval), do: Eval.skill_providers(eval) ++ eval.tools

  defp provider_source({SkillFile, opts}) when is_list(opts) do
    opts
    |> Keyword.fetch!(:path)
    |> file_hash()
  end

  defp provider_source({module, opts}) when is_atom(module) and is_list(opts) do
    beam_md5(module) <> ":" <> inspect(opts)
  end

  defp provider_source(path) when is_binary(path), do: tree_hash(path)
  defp provider_source(module) when is_atom(module), do: beam_md5(module)
  defp provider_source(spec), do: hash(inspect(spec))

  # A module's compiled hash — changes when its code changes — so an eval that
  # exercises a module provider re-runs when that module is recompiled. Falls
  # back to the name if the module isn't loaded.
  defp module_token(nil), do: ""
  defp module_token(module) when is_atom(module), do: beam_md5(module)

  defp beam_md5(module) do
    module.module_info(:md5)
  rescue
    _error -> Atom.to_string(module)
  end

  defp tree_hash(path) do
    cond do
      File.dir?(path) -> dir_hash(path)
      File.regular?(path) -> file_hash(path)
      true -> hash(path)
    end
  end

  defp dir_hash(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map_join("\n", &file_entry/1)
    |> hash()
  end

  defp file_entry(path), do: path <> ":" <> file_hash(path)

  defp file_hash(path) do
    case File.read(path) do
      {:ok, content} -> hash(content)
      {:error, _reason} -> hash(path)
    end
  end

  defp hash(data) do
    :sha256
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Term-file store
  # ---------------------------------------------------------------------------

  defp load(path) do
    case File.read(path) do
      {:ok, binary} -> decode(binary)
      {:error, _reason} -> %{}
    end
  end

  defp decode(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> %{}
  end

  defp write(path, store) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(store))
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
  end
end
