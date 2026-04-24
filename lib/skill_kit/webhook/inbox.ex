defmodule SkillKit.Webhook.Inbox do
  @moduledoc """
  Behaviour for per-agent webhook delivery persistence and dispatch.

  An inbox implementation owns three responsibilities:

    * persistence — storing verified inbound deliveries so an agent can read
      them back later via the `webhook_inbox` tool
    * dispatch — deciding when (immediately, debounced, throttled) and how
      (single pointer, coalesced batch) to notify the receiving agent via
      `SkillKit.send_event/3`
    * retention — bounding storage (LRU, TTL) so unbounded inbound traffic
      doesn't leak memory

  The default implementation is `SkillKit.Webhook.Inbox.Memory` (ETS-backed,
  immediate dispatch). Hosts can swap in File, S3, or custom impls by passing
  `{inbox: {MyInbox, opts}}` to `SkillKit.Webhook.Supervisor.start_link/1`.

  ## Entry shape

  The Plug hands off a single map containing everything the inbox needs to
  both persist the delivery and, when it decides to emit, call
  `SkillKit.send_event/3` on the agent:

      %{
        agent: %SkillKit.AgentRef{},           # how to address the receiving agent
        prompt: String.t(),                     # user-authored webhook intent
        delivery: %{
          id: String.t(),
          webhook_id: String.t(),
          agent_name: String.t(),
          received_at: DateTime.t(),
          method: String.t(),
          headers: %{String.t() => String.t()},
          query: %{String.t() => String.t()},
          body: binary()
        }
      }

  ## Read semantics

  `read/4` resolves `opts[:selector]` against the delivery's structure, then
  optionally sub-slices:

    * when the resolved value is an array: `offset` + `limit` select a range
    * when the resolved value is multi-line text: `line_start` + `line_end`
      (exclusive) select a line range
    * when the resolved value is a string/binary: `offset_bytes` + `limit_bytes`
      select a byte range

  The `limit_bytes` option is the final safety net: regardless of what slicing
  ran, the serialized result is capped at `limit_bytes` (default from inbox
  config) and `truncated: true` is set when clipped.

  Opts that don't apply to the resolved value type are silently ignored.

  ## Selector syntax

    * `""` or `"."` — the whole delivery (rare; usually select a sub-tree)
    * `"body"` — the parsed body (JSON-decoded if applicable, else raw text)
    * `"headers"` — header map
    * `"body.commits[0].message"` — dot-walk + array indexing
    * `"body.commits[].message"` — array projection (map across array)
    * `"headers.x-github-event"` — header lookup
  """

  @type inbox :: term()
  @type agent_name :: String.t()
  @type delivery_id :: String.t()

  @type delivery :: %{
          id: delivery_id(),
          webhook_id: String.t(),
          agent_name: agent_name(),
          received_at: DateTime.t(),
          method: String.t(),
          headers: %{String.t() => String.t()},
          query: %{String.t() => String.t()},
          body: binary()
        }

  @type entry :: %{
          agent: SkillKit.AgentRef.t(),
          prompt: String.t(),
          delivery: delivery()
        }

  @type summary :: %{
          id: delivery_id(),
          webhook_id: String.t(),
          received_at: DateTime.t(),
          method: String.t(),
          body_bytes: non_neg_integer(),
          headers: %{String.t() => String.t()},
          body: map()
        }

  @type read_result :: %{
          value: term(),
          bytes: non_neg_integer(),
          truncated: boolean(),
          total: non_neg_integer() | nil
        }

  @doc """
  Persist a delivery and decide when to emit it to the agent.

  The implementation is responsible for calling `SkillKit.send_event/3`
  (or whatever `:dispatch` callback it is configured with) at the right
  time. The Plug returns 202 as soon as `put/2` returns `:ok`; any delay
  in dispatch is the inbox's business, not the Plug's.
  """
  @callback put(inbox(), entry()) :: :ok

  @doc "Read a slice of a delivery. See module doc for `opts` shape."
  @callback read(inbox(), agent_name(), delivery_id(), opts :: keyword()) ::
              {:ok, read_result()} | {:error, :not_found | :invalid_selector}

  @doc "Structural sketch of one delivery (headers full, body key tree, no leaf values)."
  @callback summary(inbox(), agent_name(), delivery_id()) ::
              {:ok, summary()} | {:error, :not_found}

  @doc "Recent deliveries for an agent, newest first."
  @callback list(inbox(), agent_name(), opts :: keyword()) :: {:ok, [summary()]}

  @doc "Evict a delivery."
  @callback delete(inbox(), agent_name(), delivery_id()) :: :ok
end
