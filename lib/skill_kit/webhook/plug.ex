defmodule SkillKit.Webhook.Plug do
  @moduledoc """
  Plug that routes inbound webhook requests.

  Mounted by the host (typically via Phoenix `forward`) at the base path
  configured as the public URL root:

      forward "/webhooks", to: SkillKit.Webhook.Plug

  The path after the forward prefix is interpreted as the webhook id. A
  single request passes through `resolve/3`: look up the webhook record,
  the running agent, verify the signature, check idempotency. Depending
  on the outcome the Plug responds with one of 200 / 202 / 401 / 404 /
  500 / 503. The handshake short-circuit (Slack `url_verification`) is
  returned as-is — the verifier wrote the response itself.

  On success the Plug hands the delivery to the configured
  `SkillKit.Webhook.Inbox` impl via `Inbox.put/2`. The Inbox owns
  persistence, retention, and dispatch timing; it calls
  `SkillKit.send_event/3` on the bound agent when it decides to emit.
  The Plug returns 202 as soon as `put/2` returns `:ok`.
  """

  @behaviour Plug

  alias SkillKit.AgentRef
  alias SkillKit.Webhook
  alias SkillKit.Webhook.Idempotency
  alias SkillKit.Webhook.Registry, as: WebhookRegistry
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor

  @impl true
  def init(opts) do
    Keyword.put_new(opts, :supervisor, SkillKit.Webhook)
  end

  @impl true
  def call(%Plug.Conn{path_info: [id]} = conn, opts) do
    SkillKit.Telemetry.span(
      [:webhook, :request],
      %{id: id},
      fn ->
        result = resolve(conn, id, opts)
        final_conn = dispatch_outcome(result, conn, opts)
        {final_conn, %{outcome: request_outcome(result), status: final_conn.status}}
      end
    )
  end

  def call(%Plug.Conn{} = conn, _opts) do
    Plug.Conn.send_resp(conn, 404, "")
  end

  # -- Resolution pipeline --------------------------------------------------

  defp resolve(conn, id, opts) do
    with raw <- conn.assigns[:raw_body] || "",
         {:ok, webhook} <- Webhook.get(id, opts),
         {:ok, agent} <-
           WebhookRegistry.whereis(webhook.agent_name, registry: registry_name(opts)),
         :ok <- verify(webhook, raw, conn, agent),
         :ok <- check_idempotency(webhook, conn, opts) do
      {:ok, webhook, agent, raw}
    end
  end

  defp verify(%Webhook{verifier: {module, config}}, raw, conn, agent) do
    apply(module, :verify, [raw, conn, config, agent])
  end

  defp check_idempotency(%Webhook{idempotency: nil}, _conn, _opts), do: :ok

  defp check_idempotency(%Webhook{idempotency: config} = _webhook, conn, opts) do
    case Idempotency.extract_key(conn, config) do
      :no_key -> :ok
      {:error, :missing} -> :ok
      {:ok, key} -> dedup(key, config, opts)
    end
  end

  defp dedup(key, config, opts) do
    name = idempotency_name(opts)
    ttl = Map.get(config, :ttl, 86_400)
    Idempotency.check(name, key, ttl: ttl)
  end

  # -- Outcome dispatch -----------------------------------------------------

  defp dispatch_outcome({:ok, webhook, agent, raw}, conn, opts) do
    {inbox_mod, inbox_name} = WebhookSupervisor.inbox_ref(Keyword.fetch!(opts, :supervisor))

    entry = build_entry(webhook, agent, raw, conn)
    :ok = inbox_mod.put(inbox_name, entry)
    Plug.Conn.send_resp(conn, 202, "")
  end

  defp dispatch_outcome({:error, :not_found}, conn, _opts),
    do: Plug.Conn.send_resp(conn, 404, "")

  defp dispatch_outcome({:error, :agent_not_running}, conn, _opts),
    do: Plug.Conn.send_resp(conn, 503, "")

  defp dispatch_outcome({:error, :invalid_signature}, conn, _opts),
    do: Plug.Conn.send_resp(conn, 401, "")

  defp dispatch_outcome({:error, :stale_timestamp}, conn, _opts),
    do: Plug.Conn.send_resp(conn, 401, "")

  defp dispatch_outcome({:error, :misconfigured}, conn, _opts),
    do: Plug.Conn.send_resp(conn, 500, "")

  defp dispatch_outcome(:duplicate, conn, _opts),
    do: Plug.Conn.send_resp(conn, 200, "")

  defp dispatch_outcome({:handshake, conn}, _conn, _opts), do: conn

  # -- Helpers --------------------------------------------------------------

  defp request_outcome({:ok, _, _, _}), do: :dispatched
  defp request_outcome({:error, reason}), do: reason
  defp request_outcome(:duplicate), do: :duplicate
  defp request_outcome({:handshake, _conn}), do: :handshake

  defp registry_name(opts),
    do: WebhookSupervisor.registry_name(Keyword.fetch!(opts, :supervisor))

  defp idempotency_name(opts),
    do: WebhookSupervisor.idempotency_name(Keyword.fetch!(opts, :supervisor))

  defp build_entry(webhook, agent, raw, conn) do
    fetched = Plug.Conn.fetch_query_params(conn)

    %{
      agent: AgentRef.from_agent(agent),
      prompt: webhook.prompt,
      delivery: %{
        id: delivery_id(webhook, conn),
        webhook_id: webhook.id,
        agent_name: webhook.agent_name,
        received_at: DateTime.utc_now(),
        method: conn.method,
        headers: Map.new(conn.req_headers),
        query: fetched.query_params,
        body: raw
      }
    }
  end

  # Use the idempotency key as the delivery id when available (lets the
  # inbox dedup naturally), else generate a random id.
  defp delivery_id(%Webhook{idempotency: config}, conn) do
    case Idempotency.extract_key(conn, config) do
      {:ok, key} -> key
      _ -> "dlv_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    end
  end
end
