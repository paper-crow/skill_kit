defmodule SkillKit.LLM do
  @moduledoc """
  Behaviour for LLM provider adapters and dispatch entry point.

  ## Implementing a Provider

  A provider adapter implements this behaviour and returns a stream of
  `SkillKit.Event.*` structs. The adapter is responsible for:

  1. Calling the provider's API (e.g., `Anthropic.stream/3`)
  2. Converting provider-specific events to SkillKit events via the
     `SkillKit.Event.Streamable` protocol
  3. Returning `{:ok, event_stream}` or `{:error, reason}`

  ### Example adapter

      defmodule SkillKit.LLM.MyProvider do
        @behaviour SkillKit.LLM

        alias SkillKit.Event.Streamable

        @impl true
        def stream(messages, opts) do
          encoded = encode_messages(messages)

          case MyProvider.stream(encoded, opts) do
            {:ok, raw_stream} ->
              {:ok, Stream.transform(raw_stream, %{}, &Streamable.stream/2)}

            {:error, reason} ->
              {:error, reason}
          end
        end
      end

  The stream must yield these `SkillKit.Event` structs:

    * `%Delta{text: text}` — text fragment from the LLM
    * `%ToolCallStart{id: id, name: name}` — a tool call has begun
    * `%ToolCallComplete{id: id, name: name, input: map}` — tool call fully parsed
    * `%Usage{input_tokens: n, output_tokens: n}` — token counts
    * `%Done{stop_reason: reason}` — turn complete (`:end_turn` or `:tool_use`)

  See `SkillKit.Event.Streamable` for how to implement the protocol for
  your provider's event types. See `SkillKit.LLM.Anthropic` for a
  complete reference implementation.

  ## Streamable Protocol

  Each provider defines its own typed event structs (e.g., `Anthropic.Event.*`).
  SkillKit defines `SkillKit.Event.Streamable` implementations for those types,
  converting them to universal SkillKit events. The provider knows nothing about
  SkillKit — the protocol implementations live in the SkillKit codebase.

  The protocol function `stream/2` takes a provider event and an accumulator,
  returning `{[SkillKit.Event.*], updated_acc}`. The accumulator carries state
  across events (e.g., partial JSON fragments for tool call inputs).

  ## Model URI Resolution

  Providers are resolved from model URI strings:

    * `"anthropic://claude-sonnet-4-20250514?max_tokens=8096"` — full URI
    * `"claude-sonnet-4-20250514"` — bare string, uses default provider
    * `"claude-sonnet-4-20250514?max_tokens=4096"` — bare with query params

  ## Configuration

      config :skill_kit, SkillKit.LLM,
        providers: [anthropic: SkillKit.LLM.Anthropic],
        default_provider: :anthropic

      config :skill_kit, SkillKit.LLM.Anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY")
  """

  @type message ::
          SkillKit.Types.UserMessage.t()
          | SkillKit.Types.AssistantMessage.t()
          | SkillKit.Types.SystemMessage.t()
          | SkillKit.Types.ToolResult.t()

  @callback stream(messages :: [message()], opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc "Streams a response from the resolved LLM provider."
  @spec stream([message()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(messages, opts \\ []) do
    {model_string, opts} = Keyword.pop(opts, :model)

    case get_provider_and_opts(model_string) do
      {:ok, provider, provider_opts} ->
        stream_with_telemetry(provider, messages, Keyword.merge(provider_opts, opts))

      {:error, _} = err ->
        SkillKit.Telemetry.event([:llm, :stream, :error], %{}, %{error: err, model: model_string})
        err
    end
  end

  defp stream_with_telemetry(provider, messages, opts) do
    meta = %{provider: provider, model: Keyword.get(opts, :model)}

    SkillKit.Telemetry.span([:llm, :stream], meta, fn ->
      case provider.stream(messages, opts) do
        {:ok, _} = result -> {result, %{}}
        {:error, _} = error -> {error, %{error: error}}
      end
    end)
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
  def get_provider(name) when is_atom(name) do
    case Keyword.fetch(providers(), name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_provider, name}}
    end
  end

  def get_provider(name) when is_binary(name) do
    case Enum.find(providers(), fn {key, _mod} -> Atom.to_string(key) == name end) do
      {_key, mod} -> {:ok, mod}
      nil -> {:error, {:unknown_provider, name}}
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
      model_opts = query_params(query) ++ [model: model_name]
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

  # Model-URI query params ride along under a single `:params` key as an
  # opaque string map. The resolver makes no assumptions about which params
  # a provider supports or their types, and never atomizes URI input — each
  # provider picks out and coerces the params it understands.
  defp query_params(nil), do: []
  defp query_params(query), do: [params: URI.decode_query(query)]
end
