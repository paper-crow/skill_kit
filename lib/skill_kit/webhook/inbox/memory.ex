defmodule SkillKit.Webhook.Inbox.Memory do
  @moduledoc """
  In-memory `SkillKit.Webhook.Inbox` implementation backed by an ETS table
  and a `GenServer` owner.

  Suitable for dev, tests, and single-node deployments. Deliveries are lost
  on BEAM restart.

  ## Config

  Accepts the following options on `start_link/1`:

    * `:name` (required) — the registered name for the owning GenServer
      (also the inbox handle passed to callbacks)
    * `:max_deliveries` — per-agent LRU cap (default 500)
    * `:ttl_ms` — entries older than this are treated as `:not_found`
      (default 24h)
    * `:default_limit_bytes` — cap applied to `read/4` results when the
      caller does not set `:limit_bytes` (default 4096)
    * `:dispatch` — controls whether/how `put/2` notifies the agent after
      persisting. One of:
        * `:immediate` (default) — calls `SkillKit.Webhook.Inbox.dispatch/1`
        * `:none` — persist only, no notification
        * a 1-arity function `fn entry -> :ok` — invoked with the full
          entry (primarily for tests that need to intercept dispatch)
  """

  @behaviour SkillKit.Webhook.Inbox

  use GenServer

  alias SkillKit.Webhook.Inbox

  @default_max 500
  @default_ttl :timer.hours(24)
  @default_limit_bytes 4096

  # -- Public API (behaviour callbacks dispatch through here) --------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl SkillKit.Webhook.Inbox
  def put(inbox, entry) do
    GenServer.call(inbox, {:put, entry})
  end

  @impl SkillKit.Webhook.Inbox
  def read(inbox, agent_name, delivery_id, opts) do
    GenServer.call(inbox, {:read, agent_name, delivery_id, opts})
  end

  @impl SkillKit.Webhook.Inbox
  def summary(inbox, agent_name, delivery_id) do
    GenServer.call(inbox, {:summary, agent_name, delivery_id})
  end

  @impl SkillKit.Webhook.Inbox
  def list(inbox, agent_name, opts) do
    GenServer.call(inbox, {:list, agent_name, opts})
  end

  @impl SkillKit.Webhook.Inbox
  def delete(inbox, agent_name, delivery_id) do
    GenServer.call(inbox, {:delete, agent_name, delivery_id})
  end

  # -- GenServer ------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    table =
      :ets.new(Module.concat(name, Table), [:set, :protected, read_concurrency: true])

    state = %{
      name: name,
      table: table,
      order: %{},
      max_deliveries: Keyword.get(opts, :max_deliveries, @default_max),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl),
      default_limit_bytes: Keyword.get(opts, :default_limit_bytes, @default_limit_bytes),
      dispatch: Keyword.get(opts, :dispatch, :immediate)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:put, entry}, _from, state) do
    %{delivery: delivery} = entry
    expires_at = now_ms() + state.ttl_ms
    key = {delivery.agent_name, delivery.id}

    :ets.insert(state.table, {key, delivery, expires_at})

    order = push_order(state.order, delivery.agent_name, delivery.id)
    order = evict_over_cap(order, delivery.agent_name, state)

    maybe_dispatch(state.dispatch, entry, {__MODULE__, state.name})

    {:reply, :ok, %{state | order: order}}
  end

  def handle_call({:read, agent_name, delivery_id, opts}, _from, state) do
    {:reply, do_read(state, agent_name, delivery_id, opts), state}
  end

  def handle_call({:summary, agent_name, delivery_id}, _from, state) do
    {:reply, do_summary(state, agent_name, delivery_id), state}
  end

  def handle_call({:list, agent_name, _opts}, _from, state) do
    ids = Map.get(state.order, agent_name, [])

    summaries =
      ids
      |> Enum.map(&fetch_live(state, agent_name, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&build_summary/1)

    {:reply, {:ok, summaries}, state}
  end

  def handle_call({:delete, agent_name, delivery_id}, _from, state) do
    :ets.delete(state.table, {agent_name, delivery_id})
    order = Map.update(state.order, agent_name, [], &List.delete(&1, delivery_id))
    {:reply, :ok, %{state | order: order}}
  end

  # -- Put helpers ----------------------------------------------------------

  defp push_order(order, agent_name, delivery_id) do
    Map.update(order, agent_name, [delivery_id], fn existing ->
      [delivery_id | List.delete(existing, delivery_id)]
    end)
  end

  defp evict_over_cap(order, agent_name, state) do
    ids = Map.get(order, agent_name, [])

    case length(ids) > state.max_deliveries do
      true ->
        {keep, drop} = Enum.split(ids, state.max_deliveries)
        Enum.each(drop, &:ets.delete(state.table, {agent_name, &1}))
        Map.put(order, agent_name, keep)

      false ->
        order
    end
  end

  defp maybe_dispatch(:immediate, entry, inbox_ref), do: Inbox.dispatch(entry, inbox_ref)
  defp maybe_dispatch(:none, _entry, _inbox_ref), do: :ok
  defp maybe_dispatch(fun, entry, _inbox_ref) when is_function(fun, 1), do: fun.(entry)

  # -- Read / Summary / List -----------------------------------------------

  defp do_read(state, agent_name, delivery_id, opts) do
    with {:ok, delivery} <- fetch_or_not_found(state, agent_name, delivery_id),
         {:ok, value} <- resolve_selector(delivery, Keyword.get(opts, :selector, "")) do
      cap = Keyword.get(opts, :limit_bytes, state.default_limit_bytes)
      {:ok, slice_and_format(value, opts, cap)}
    end
  end

  defp do_summary(state, agent_name, delivery_id) do
    case fetch_or_not_found(state, agent_name, delivery_id) do
      {:ok, delivery} -> {:ok, build_summary(delivery)}
      err -> err
    end
  end

  defp fetch_or_not_found(state, agent_name, delivery_id) do
    case :ets.lookup(state.table, {agent_name, delivery_id}) do
      [{_key, delivery, expires_at}] ->
        check_ttl(delivery, expires_at)

      [] ->
        {:error, :not_found}
    end
  end

  defp check_ttl(delivery, expires_at) do
    case expires_at > now_ms() do
      true -> {:ok, delivery}
      false -> {:error, :not_found}
    end
  end

  defp fetch_live(state, agent_name, delivery_id) do
    case fetch_or_not_found(state, agent_name, delivery_id) do
      {:ok, delivery} -> delivery
      _ -> nil
    end
  end

  # -- Selector parsing and resolution -------------------------------------

  defp resolve_selector(delivery, selector) when selector in ["", "."] do
    {:ok, delivery}
  end

  defp resolve_selector(delivery, selector) when is_binary(selector) do
    tokens = parse_selector(selector)
    walk(tokens, delivery_view(delivery))
  end

  defp parse_selector(selector) do
    selector
    |> String.split(".")
    |> Enum.flat_map(&split_brackets/1)
  end

  defp split_brackets(segment) do
    case Regex.run(~r/^([^\[]+)(.*)$/, segment) do
      [_, name, rest] -> [name | parse_brackets(rest)]
      _ -> [segment]
    end
  end

  defp parse_brackets(""), do: []
  defp parse_brackets("[]" <> rest), do: [:project | parse_brackets(rest)]

  defp parse_brackets("[" <> rest) do
    [index_part, tail] = String.split(rest, "]", parts: 2)
    {int, ""} = Integer.parse(index_part)
    [{:idx, int} | parse_brackets(tail)]
  end

  defp delivery_view(%{} = delivery) do
    %{
      "body" => decode_body(delivery.body),
      "headers" => delivery.headers,
      "query" => delivery.query,
      "method" => delivery.method,
      "id" => delivery.id,
      "webhook_id" => delivery.webhook_id,
      "received_at" => DateTime.to_iso8601(delivery.received_at)
    }
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp walk([], value), do: {:ok, value}

  defp walk([key | rest], map) when is_binary(key) and is_map(map) do
    case Map.fetch(map, key) do
      {:ok, sub} -> walk(rest, sub)
      :error -> {:error, :invalid_selector}
    end
  end

  defp walk([{:idx, i} | rest], list) when is_list(list) do
    case Enum.at(list, i, :__missing__) do
      :__missing__ -> {:error, :invalid_selector}
      value -> walk(rest, value)
    end
  end

  defp walk([:project | rest], list) when is_list(list) do
    projected =
      Enum.reduce_while(list, [], fn item, acc ->
        case walk(rest, item) do
          {:ok, value} -> {:cont, [value | acc]}
          {:error, _} -> {:halt, :error}
        end
      end)

    project_result(projected)
  end

  defp walk(_tokens, _value), do: {:error, :invalid_selector}

  defp project_result(:error), do: {:error, :invalid_selector}
  defp project_result(list) when is_list(list), do: {:ok, Enum.reverse(list)}

  # -- Slicing + formatting -------------------------------------------------

  defp slice_and_format(value, opts, cap) when is_list(value) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit)
    total = length(value)

    sliced =
      case limit do
        nil -> Enum.drop(value, offset)
        n when is_integer(n) -> value |> Enum.drop(offset) |> Enum.take(n)
      end

    apply_byte_cap(sliced, cap, total)
  end

  defp slice_and_format(value, opts, cap) when is_binary(value) do
    format_string(value, opts, cap)
  end

  defp slice_and_format(value, _opts, cap) do
    apply_byte_cap(value, cap, nil)
  end

  defp format_string(value, opts, cap) do
    case line_range_opts(opts) do
      nil -> byte_range_format(value, opts, cap)
      {line_start, line_end} -> line_range_format(value, line_start, line_end, cap)
    end
  end

  defp line_range_opts(opts) do
    with start when is_integer(start) <- Keyword.get(opts, :line_start),
         finish when is_integer(finish) <- Keyword.get(opts, :line_end) do
      {start, finish}
    else
      _ -> nil
    end
  end

  defp line_range_format(value, line_start, line_end, cap) do
    lines = String.split(value, "\n")
    total = length(lines)
    sliced = lines |> Enum.slice(line_start, max(line_end - line_start, 0)) |> Enum.join("\n")
    apply_byte_cap(sliced, cap, total)
  end

  defp byte_range_format(value, opts, cap) do
    offset_bytes = Keyword.get(opts, :offset_bytes, 0)
    explicit_limit = Keyword.get(opts, :limit_bytes)
    total_bytes = byte_size(value)
    effective_limit = explicit_limit || cap
    sliced = safe_binary_slice(value, offset_bytes, effective_limit)

    %{
      value: sliced,
      bytes: byte_size(sliced),
      truncated: byte_size(sliced) < total_bytes - offset_bytes,
      total: total_bytes
    }
  end

  defp safe_binary_slice(binary, offset, _length) when offset >= byte_size(binary), do: ""

  defp safe_binary_slice(binary, offset, length) do
    available = byte_size(binary) - offset
    :binary.part(binary, offset, min(length, available))
  end

  defp apply_byte_cap(value, cap, total) do
    serialized = serialize(value)
    bytes = byte_size(serialized)

    case bytes > cap do
      true ->
        capped = :binary.part(serialized, 0, cap)
        decoded = maybe_decode(capped, value)
        %{value: decoded, bytes: cap, truncated: true, total: total || bytes}

      false ->
        %{value: value, bytes: bytes, truncated: false, total: total}
    end
  end

  defp serialize(value) when is_binary(value), do: value
  defp serialize(value), do: Jason.encode!(value)

  defp maybe_decode(capped, original) when is_binary(original), do: capped
  defp maybe_decode(capped, _original), do: capped

  # -- Summary shape --------------------------------------------------------

  defp build_summary(delivery) do
    body_shape =
      case Jason.decode(delivery.body) do
        {:ok, decoded} -> shape(decoded, 2)
        _ -> %{"type" => "text", "bytes" => byte_size(delivery.body)}
      end

    %{
      id: delivery.id,
      webhook_id: delivery.webhook_id,
      received_at: delivery.received_at,
      method: delivery.method,
      body_bytes: byte_size(delivery.body),
      headers: delivery.headers,
      body: body_shape
    }
  end

  defp shape(_value, 0), do: %{"type" => "truncated"}

  defp shape(value, _depth) when is_binary(value),
    do: %{"type" => "string", "bytes" => byte_size(value)}

  defp shape(value, _depth) when is_number(value), do: %{"type" => "number"}
  defp shape(value, _depth) when is_boolean(value), do: %{"type" => "boolean"}
  defp shape(nil, _depth), do: %{"type" => "null"}

  defp shape(value, depth) when is_list(value) do
    sample = Enum.take(value, 3)
    sample_keys = sample |> Enum.flat_map(&sample_keys_of/1) |> Enum.uniq()

    %{
      "type" => "array",
      "length" => length(value),
      "sample_keys" => sample_keys,
      "sample" => Enum.map(sample, &shape(&1, depth - 1))
    }
  end

  defp shape(value, depth) when is_map(value) do
    keys = Map.new(value, fn {k, v} -> {to_string(k), shape(v, depth - 1)} end)
    %{"type" => "object", "keys" => keys}
  end

  defp sample_keys_of(%{} = map), do: Map.keys(map) |> Enum.map(&to_string/1)
  defp sample_keys_of(_), do: []

  # -- Time ------------------------------------------------------------------

  defp now_ms, do: System.monotonic_time(:millisecond) + System.time_offset(:millisecond)
end
