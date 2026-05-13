defmodule Mix.Tasks.SkillKit.Chat.WebhookHostTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SkillKit.Chat.WebhookHost
  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook
  alias SkillKit.Webhook.Inbox.Memory, as: InboxMemory
  alias SkillKit.Webhook.Registry, as: WebhookRegistry
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor
  alias SkillKit.Webhook.Verifier.None

  setup do
    # WebhookHost forwards to SkillKit.Webhook.Plug with default opts, so
    # the supervisor must be registered under the default name.
    {:ok, sup_pid} =
      WebhookSupervisor.start_link(inbox: {InboxMemory, [dispatch: :none]})

    on_exit(fn ->
      if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid)
    end)

    reg_atom = :"#{__MODULE__}_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.start_link(keys: :unique, name: reg_atom)

    agent = %SkAgent{
      name: "host-agent",
      description: "t",
      system_prompt: "",
      registry: reg_atom,
      caller: self()
    }

    {:ok, _} = Registry.register(reg_atom, {"host-agent", :mailbox}, nil)
    registry = WebhookSupervisor.registry_name(SkillKit.Webhook)
    :ok = WebhookRegistry.attach(agent, registry: registry)

    {:ok, agent: agent}
  end

  defp call(method, path, body) do
    conn =
      method
      |> Plug.Test.conn(path, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    WebhookHost.call(conn, WebhookHost.init([]))
  end

  test "returns 404 when the webhook id is unknown" do
    conn = call(:post, "/missing", "")
    assert conn.status == 404
  end

  test "reads the raw body, forwards to the Plug, and persists the delivery", %{agent: agent} do
    webhook = %Webhook{
      id: "ok",
      agent_name: agent.name,
      prompt: "Echo the body back.",
      verifier: {None, %{}},
      inserted_at: DateTime.utc_now()
    }

    :ok = Webhook.register(webhook)

    body = ~s({"hello":"world"})
    conn = call(:post, "/ok", body)
    assert conn.status == 202

    inbox = WebhookSupervisor.inbox_name(SkillKit.Webhook)
    {:ok, [summary]} = InboxMemory.list(inbox, agent.name, [])
    assert summary.webhook_id == "ok"
    assert summary.method == "POST"
    assert summary.body_bytes == byte_size(body)

    {:ok, read} = InboxMemory.read(inbox, agent.name, summary.id, selector: "body.hello")
    assert read.value == "world"
  end
end
