defmodule SkillKit.LLM do
  @moduledoc """
  Behaviour for LLM provider adapters and dispatch entry point.

  Defines a single callback `stream/3` that adapters must implement.
  The `stream/2` function dispatches to the configured backend, which
  is a `{module, config}` tuple read from application config.

  ## Configuration

      config :skill_kit, SkillKit.LLM,
        {SkillKit.LLM.Anthropic, [
          api_key: System.get_env("ANTHROPIC_API_KEY"),
          endpoint: "https://api.anthropic.com"
        ]}

  ## Backend Override

  Callers can override the backend per-call via the `:backend` option:

      SkillKit.LLM.stream(messages, backend: {SkillKit.LLM.Anthropic, config})
  """

  @type message :: map()

  @callback stream(config :: keyword(), messages :: [message()], opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Streams a response from the configured (or overridden) LLM backend.

  Pops `:backend` from `opts` if present; otherwise reads the default
  from application config as a `{module, config}` tuple.
  """
  @spec stream([message()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(messages, opts \\ []) do
    {backend, opts} = Keyword.pop(opts, :backend)
    {mod, config} = backend || default_backend_tuple()
    mod.stream(config, messages, opts)
  end

  @doc "Returns the configured default backend as `{module, config}`."
  @spec default_backend() :: {:ok, {module(), keyword()}}
  def default_backend do
    {:ok, default_backend_tuple()}
  end

  defp default_backend_tuple do
    Application.get_env(:skill_kit, __MODULE__, {__MODULE__.Anthropic, []})
  end
end
