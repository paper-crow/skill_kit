defmodule SkillKit.Webhook.TelemetryTest do
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
    sup = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    {:ok, _pid} = WebhookSupervisor.start_link(name: sup)

    reg_atom = :"reg_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(keys: :unique, name: reg_atom)
    Registry.register(reg_atom, {"agent", :mailbox}, nil)

    agent = %SkAgent{
      name: "agent",
      description: "",
      system_prompt: "",
      registry: reg_atom,
      caller: self()
    }

    WebhookRegistry.attach(agent, registry: WebhookSupervisor.registry_name(sup))

    :telemetry.attach_many(
      "test-#{System.unique_integer([:positive])}",
      [
        [:skill_kit, :webhook, :request, :start],
        [:skill_kit, :webhook, :request, :stop],
        [:skill_kit, :webhook, :verification, :start],
        [:skill_kit, :webhook, :verification, :stop]
      ],
      fn event, meas, meta, pid -> send(pid, {:telemetry, event, meas, meta}) end,
      self()
    )

    {:ok, supervisor: sup}
  end

  test "emits request and verification spans on happy path", %{supervisor: sup} do
    secret = "s"
    stub(SkillKit.CredentialProvider.Mock, :fetch, fn _tool, _agent, "GH" -> {:ok, secret} end)

    body = "hello"
    sig = :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)

    webhook = %Webhook{
      id: "tele-1",
      agent_name: "agent",
      prompt: "b: $WEBHOOK_BODY",
      verifier: {Github, %{secret_key: "GH"}},
      inserted_at: DateTime.utc_now()
    }

    Webhook.register(webhook, supervisor: sup)

    conn =
      :post
      |> Plug.Test.conn("/tele-1", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=#{sig}")
      |> Map.put(:path_info, ["tele-1"])

    WebhookPlug.call(conn, WebhookPlug.init(supervisor: sup))

    assert_receive {:telemetry, [:skill_kit, :webhook, :request, :start], _, _}
    assert_receive {:telemetry, [:skill_kit, :webhook, :verification, :start], _, _}
    assert_receive {:telemetry, [:skill_kit, :webhook, :verification, :stop], _, meta_v}
    assert meta_v[:outcome] == :ok
    assert_receive {:telemetry, [:skill_kit, :webhook, :request, :stop], _, meta_r}
    assert meta_r[:outcome] == :dispatched
    assert meta_r[:status] == 202
  end
end
