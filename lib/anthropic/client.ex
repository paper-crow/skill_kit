defmodule Anthropic.Client do
  @moduledoc """
  Struct holding Anthropic API connection configuration.

  Used by `Anthropic.stream/3` to build HTTP requests. Struct-based
  so tests can pass config directly without global state.
  """

  @default_endpoint "https://api.anthropic.com"

  @api_version "2023-06-01"

  @max_retries 3

  @type t :: %__MODULE__{
          api_key: String.t(),
          endpoint: String.t()
        }

  @enforce_keys [:api_key]
  defstruct [
    :api_key,
    endpoint: @default_endpoint
  ]

  @doc "Creates a new client from a keyword list. `:api_key` is required."
  @spec new(keyword()) :: t()
  def new(opts) do
    _ = Keyword.fetch!(opts, :api_key)
    struct!(__MODULE__, opts)
  end

  @doc """
  Sends a streaming request to the Anthropic Messages API.

  Returns `{:ok, Enumerable.t()}` where each element is a parsed
  JSON map from an SSE `data:` line. Non-data lines are skipped.

  `opts` are merged into the request body (e.g. `model`, `max_tokens`).
  """
  @spec stream(t(), list(map()), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(%__MODULE__{} = client, messages, opts \\ []) do
    do_stream(client, messages, opts, 0)
  end

  defp do_stream(client, messages, opts, retry_count) do
    body =
      opts
      |> Keyword.take([:model, :max_tokens, :system, :tools, :temperature, :top_p])
      |> Map.new()
      |> Map.put(:messages, messages)
      |> Map.put(:stream, true)

    case Req.post(
           url: client.endpoint <> "/v1/messages",
           headers: [
             {"x-api-key", client.api_key},
             {"anthropic-version", @api_version},
             {"content-type", "application/json"}
           ],
           json: body,
           into: :self
         ) do
      {:ok, %{status: 200} = resp} ->
        {:ok, sse_stream(resp.body)}

      {:ok, %{status: 429} = resp} when retry_count < @max_retries ->
        retry_after = parse_retry_after(resp)

        :telemetry.execute(
          [:skill_kit, :llm, :rate_limited],
          %{retry_after: retry_after, attempt: retry_count + 1},
          %{endpoint: client.endpoint}
        )

        Process.sleep(retry_after)
        do_stream(client, messages, opts, retry_count + 1)

      {:ok, resp} ->
        {:error, {resp.status, resp.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_retry_after(%{headers: headers}) do
    case Map.get(headers, "retry-after") do
      [value | _] -> String.to_integer(value) * 1000
      _ -> 1000
    end
  end

  defp sse_stream(async_body) do
    Stream.flat_map(async_body, fn chunk ->
      chunk
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
    end)
  end
end
