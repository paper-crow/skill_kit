defmodule SkillKit.LLM do
  @moduledoc """
  Behaviour for LLM provider adapters and dispatch entry point.

  Resolves providers from model URI strings:

  - `"anthropic://claude-sonnet-4-20250514?max_tokens=8096"` — full URI
  - `"claude-sonnet-4-20250514"` — bare string, uses default provider
  - `"claude-sonnet-4-20250514?max_tokens=4096"` — bare with params

  ## Configuration

      config :skill_kit, SkillKit.LLM,
        providers: [anthropic: SkillKit.LLM.Anthropic],
        default_provider: :anthropic

      config :skill_kit, SkillKit.LLM.Anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY")
  """

  @type message :: SkillKit.LLM.Message.t()

  @callback stream(messages :: [message()], opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc "Streams a response from the resolved LLM provider."
  @spec stream([message()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(messages, opts \\ []) do
    {model_string, opts} = Keyword.pop(opts, :model)

    case get_provider_and_opts(model_string) do
      {:ok, provider, provider_opts} ->
        merged = Keyword.merge(provider_opts, opts)
        provider.stream(messages, merged)

      {:error, _} = err ->
        err
    end
  end

  @doc "Resolves a model URI to `{:ok, provider, opts}` or `{:error, reason}`."
  @spec get_provider_and_opts(String.t() | nil) :: {:ok, module(), keyword()} | {:error, term()}
  def get_provider_and_opts(nil) do
    provider = default_provider()
    config = Application.get_env(:skill_kit, provider, [])
    {:ok, provider, config}
  end

  def get_provider_and_opts(model) when is_binary(model) do
    model
    |> URI.parse()
    |> resolve_uri()
  end

  @doc "Looks up a provider module by scheme name."
  @spec get_provider(atom() | String.t()) :: {:ok, module()} | {:error, term()}
  def get_provider(name) when is_binary(name) do
    name
    |> String.to_existing_atom()
    |> get_provider()
  rescue
    ArgumentError -> {:error, {:unknown_provider, name}}
  end

  def get_provider(name) when is_atom(name) do
    case Keyword.fetch(providers(), name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_provider, name}}
    end
  end

  # --- URI Resolution (recursive normalization) ---

  defp resolve_uri(%URI{scheme: nil} = uri) do
    default_key = Keyword.get(llm_config(), :default_provider, :anthropic)
    resolve_uri(%{uri | scheme: to_string(default_key)})
  end

  defp resolve_uri(%URI{host: nil, path: path} = uri) when is_binary(path) do
    resolve_uri(%{uri | host: path, path: nil})
  end

  defp resolve_uri(%URI{scheme: scheme, host: model_name, query: query}) do
    with {:ok, mod} <- get_provider(scheme) do
      config = Application.get_env(:skill_kit, mod, [])
      model_opts = parse_query_params(query) ++ [model: model_name]
      {:ok, mod, Keyword.merge(config, model_opts)}
    end
  end

  # --- Config ---

  defp llm_config, do: Application.get_env(:skill_kit, __MODULE__, [])

  defp providers do
    Keyword.get(llm_config(), :providers, anthropic: __MODULE__.Anthropic)
  end

  defp default_provider do
    key = Keyword.get(llm_config(), :default_provider, :anthropic)
    Keyword.fetch!(providers(), key)
  end

  # --- Query Params ---

  @integer_params ~w(max_tokens)
  @float_params ~w(temperature top_p)

  defp parse_query_params(nil), do: []

  defp parse_query_params(query) do
    query
    |> URI.decode_query()
    |> Enum.map(&coerce_param/1)
  end

  defp coerce_param({key, value}) when key in @integer_params do
    case Integer.parse(value) do
      {int, ""} -> {String.to_atom(key), int}
      _ -> {String.to_atom(key), value}
    end
  end

  defp coerce_param({key, value}) when key in @float_params do
    case Float.parse(value) do
      {float, ""} -> {String.to_atom(key), float}
      _ -> {String.to_atom(key), value}
    end
  end

  defp coerce_param({key, value}), do: {String.to_atom(key), value}
end
