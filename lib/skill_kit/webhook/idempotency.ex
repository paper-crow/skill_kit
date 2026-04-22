defmodule SkillKit.Webhook.Idempotency do
  @moduledoc """
  Bounded ETS-backed dedup cache for webhook deliveries.

  Vendors retry deliveries on non-2xx responses (Stripe for 72h, Slack
  continuously). When a registration opts into idempotency, this module
  remembers the delivery key for a TTL window so repeat deliveries return
  200 without re-dispatching to the agent.

  Key sources supported in the registration config:

  - `%{"header" => "x-github-delivery"}` — read from request headers.
  - `%{"json_path" => "$.id"}` — read from the raw body interpreted as
    JSON (top-level field only; full JSONPath is out of scope for v1).

  Entries are swept lazily on access — each `check/3` call checks the
  stored `expires_at` and treats an expired entry as first-sight.
  """

  use GenServer

  @type config :: %{
          optional(:key) => %{optional(String.t()) => String.t()},
          optional(:ttl) => pos_integer()
        }

  # -- Public API -----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Checks whether `key` has been seen within the TTL window.

  Returns `:ok` on first sight (and records the key) or `:duplicate`
  if the key is still valid.
  """
  @spec check(atom(), String.t(), keyword()) :: :ok | :duplicate
  def check(name, key, opts) when is_binary(key) do
    ttl = Keyword.get(opts, :ttl, 86_400)
    now = System.system_time(:second)
    table = table_for(name)

    case :ets.lookup(table, key) do
      [{^key, expires_at}] when expires_at > now ->
        :duplicate

      _ ->
        :ets.insert(table, {key, now + ttl})
        :ok
    end
  end

  @doc """
  Extracts the idempotency key from the request per the registration's
  `key` config. Returns `:no_key` when idempotency is not configured,
  or `{:error, :missing}` when configured but the key is absent.
  """
  @spec extract_key(Plug.Conn.t(), config() | nil) ::
          {:ok, String.t()} | :no_key | {:error, :missing}
  def extract_key(_conn, nil), do: :no_key
  def extract_key(_conn, %{key: nil}), do: :no_key

  def extract_key(conn, %{key: %{"header" => header}}) when is_binary(header) do
    case Plug.Conn.get_req_header(conn, String.downcase(header)) do
      [value | _] -> {:ok, value}
      [] -> {:error, :missing}
    end
  end

  def extract_key(conn, %{key: %{"json_path" => "$." <> field}}) do
    read_json_field(conn.assigns[:raw_body], field)
  end

  # -- GenServer ------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    :ets.new(table_for(name), [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{name: name}}
  end

  # -- Helpers --------------------------------------------------------------

  defp table_for(name), do: Module.concat(name, Table)

  defp read_json_field(nil, _field), do: {:error, :missing}

  defp read_json_field(raw_body, field) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = map} -> fetch_field(map, field)
      _ -> {:error, :missing}
    end
  end

  defp fetch_field(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:ok, to_string(value)}
      :error -> {:error, :missing}
    end
  end
end
