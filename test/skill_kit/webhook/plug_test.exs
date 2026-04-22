defmodule SkillKit.Webhook.PlugTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook
  alias SkillKit.Webhook.Plug, as: WebhookPlug
  alias SkillKit.Webhook.Registry, as: WebhookRegistry
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor
  alias SkillKit.Webhook.Verifier.Github

  setup :verify_on_exit!

  setup do
    name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    {:ok, _pid} = WebhookSupervisor.start_link(name: name)

    # Spin up a fake agent registry so whereis has a live PID to monitor.
    reg_atom = :"registry_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.start_link(keys: :unique, name: reg_atom)

    agent = %SkAgent{
      name: "plug-agent",
      description: "t",
      system_prompt: "",
      registry: reg_atom,
      caller: self()
    }

    {:ok, _} = Registry.register(reg_atom, {"plug-agent", :mailbox}, nil)

    WebhookRegistry.attach(agent, registry: WebhookSupervisor.registry_name(name))

    {:ok, supervisor: name, agent: agent}
  end

  defp make_webhook(id, agent_name, verifier) do
    %Webhook{
      id: id,
      agent_name: agent_name,
      prompt: "evt: $WEBHOOK_BODY",
      verifier: verifier,
      inserted_at: DateTime.utc_now()
    }
  end

  defp plug_call(id, body, headers, supervisor) do
    conn = :post |> Plug.Test.conn("/" <> id, body) |> Plug.Conn.assign(:raw_body, body)

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)

    conn =
      conn
      |> Map.put(:path_info, [id])
      |> Map.put(:script_name, ["webhooks"])

    WebhookPlug.call(conn, WebhookPlug.init(supervisor: supervisor))
  end

  test "404 when the webhook id is unknown", %{supervisor: sup} do
    conn = plug_call("missing", "", [], sup)
    assert conn.status == 404
  end

  test "503 when agent is not attached", %{supervisor: sup} do
    webhook = make_webhook("orphan", "no-such-agent", {Github, %{secret_key: "GH"}})
    Webhook.register(webhook, supervisor: sup)
    conn = plug_call("orphan", "", [], sup)
    assert conn.status == 503
  end

  test "401 when signature is invalid", %{supervisor: sup} do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "GH" -> {:ok, "secret"} end)

    webhook = make_webhook("bad-sig", "plug-agent", {Github, %{secret_key: "GH"}})
    Webhook.register(webhook, supervisor: sup)

    conn =
      plug_call(
        "bad-sig",
        "body",
        [{"x-hub-signature-256", "sha256=" <> String.duplicate("0", 64)}],
        sup
      )

    assert conn.status == 401
  end

  test "500 when CredentialProvider returns nil", %{supervisor: sup} do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "GH" -> {:ok, nil} end)

    webhook = make_webhook("noconfig", "plug-agent", {Github, %{secret_key: "GH"}})
    Webhook.register(webhook, supervisor: sup)

    conn =
      plug_call(
        "noconfig",
        "body",
        [{"x-hub-signature-256", "sha256=" <> String.duplicate("0", 64)}],
        sup
      )

    assert conn.status == 500
  end

  test "202 on happy path and the agent mailbox gets a rendered message",
       %{supervisor: sup, agent: agent} do
    secret = "sekret"

    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "GH" -> {:ok, secret} end)

    webhook = make_webhook("ok", "plug-agent", {Github, %{secret_key: "GH"}})
    Webhook.register(webhook, supervisor: sup)

    body = ~s({"hello":"world"})
    sig = :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)

    conn = plug_call("ok", body, [{"x-hub-signature-256", "sha256=#{sig}"}], sup)
    assert conn.status == 202

    # The fake agent registry we set up is registered with the mailbox
    # process as `self()`, so the cast lands here.
    assert_receive {:"$gen_cast", {:message, %SkillKit.Types.UserMessage{content: content}}}, 500
    assert content =~ "evt: " <> body
  end
end
