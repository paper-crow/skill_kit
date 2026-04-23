defmodule SkillKit.Webhook.IntegrationTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Storage
  alias SkillKit.Webhook
  alias SkillKit.Webhook.Plug, as: WebhookPlug
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor
  alias SkillKit.Webhook.Verifier.Github

  @fixtures_disk Path.expand("../../fixtures/agents/webhook_integration", __DIR__)

  setup :verify_on_exit!

  setup do
    start_supervised!(Storage.Memory)
    seed_fixture_tree(@fixtures_disk, @fixtures_disk)

    sup = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    {:ok, _pid} = WebhookSupervisor.start_link(name: sup)

    handler_name = "integration-turn-start-#{inspect(self())}"

    :telemetry.attach(
      handler_name,
      [:skill_kit, :turn, :start],
      fn _event, _meas, meta, owner ->
        send(owner, {:telemetry_turn_start, meta[:agent_name]})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_name) end)

    {:ok, agent} =
      SkillKit.start_agent(@fixtures_disk,
        skills: [{SkillKit.Tools.Webhook, supervisor: sup, verifiers: %{"github" => Github}}],
        caller: self()
      )

    on_exit(fn ->
      try do
        SkillKit.stop_agent(agent)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, supervisor: sup, agent: agent}
  end

  test "full round-trip: register skill → plug hit → agent message",
       %{supervisor: sup, agent: agent} do
    # 1. Register a webhook directly through the facade (simulating what
    #    webhook:register would do; skill activation through the LLM is
    #    covered in SkillKit.Tools.WebhookTest).
    webhook = %Webhook{
      id: "integration-1",
      agent_name: agent.name,
      prompt: "inbound: $WEBHOOK_BODY",
      verifier: {Github, %{secret_key: "GH"}},
      inserted_at: DateTime.utc_now()
    }

    :ok = Webhook.register(webhook, supervisor: sup)

    # 2. Stub the credential provider.
    secret = "integ_secret"
    stub(SkillKit.CredentialProvider.Mock, :fetch, fn _tool, _agent, "GH" -> {:ok, secret} end)

    # 3. Build a valid GitHub request and invoke the Plug.
    body = ~s({"ref":"refs/heads/main"})
    sig = :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)

    conn =
      :post
      |> Plug.Test.conn("/integration-1", body)
      |> Plug.Conn.assign(:raw_body, body)
      |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=#{sig}")
      |> Map.put(:path_info, ["integration-1"])

    conn = WebhookPlug.call(conn, WebhookPlug.init(supervisor: sup))
    assert conn.status == 202

    # 4. Assert the agent's turn starts — confirming the rendered prompt
    #    reached the mailbox and the agent began processing it.
    agent_name = agent.name
    assert_receive {:telemetry_turn_start, ^agent_name}, 2_000
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_fixture_tree(disk_path, storage_path) do
    Storage.ensure_dir!(storage_path)

    case File.ls(disk_path) do
      {:ok, entries} -> Enum.each(entries, &seed_entry(disk_path, storage_path, &1))
      {:error, _} -> :ok
    end
  end

  defp seed_entry(disk_path, storage_path, entry) do
    disk_entry = Path.join(disk_path, entry)
    storage_entry = Path.join(storage_path, entry)

    if File.dir?(disk_entry) do
      seed_fixture_tree(disk_entry, storage_entry)
    else
      {:ok, content} = File.read(disk_entry)
      Storage.put!(storage_entry, content)
    end
  end
end
