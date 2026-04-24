defmodule SkillKit.Webhook.IntegrationTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Event.Delta
  alias SkillKit.Storage
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage
  alias SkillKit.Webhook
  alias SkillKit.Webhook.Plug, as: WebhookPlug
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor
  alias SkillKit.Webhook.Verifier.Github

  @fixtures_disk Path.expand("../../fixtures/agents/webhook_integration", __DIR__)

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    start_supervised!(Storage.Memory)
    seed_fixture_tree(@fixtures_disk, @fixtures_disk)

    sup = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    {:ok, _pid} = WebhookSupervisor.start_link(name: sup)

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

  test "full round-trip: register webhook → plug hit → Inbox → send_event → turn pair",
       %{supervisor: sup, agent: agent} do
    webhook = %Webhook{
      id: "integration-1",
      agent_name: agent.name,
      prompt: "Echo the webhook payload back to the user.",
      verifier: {Github, %{secret_key: "GH"}},
      inserted_at: DateTime.utc_now()
    }

    :ok = Webhook.register(webhook, supervisor: sup)

    secret = "integ_secret"
    stub(SkillKit.CredentialProvider.Mock, :fetch, fn _tool, _agent, "GH" -> {:ok, secret} end)
    SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "delivery handled"})

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

    agent_name = agent.name
    sub_prefix = "#{agent_name}/delivery:integration-1"

    assert_receive %Delta{text: "delivery handled", agent: ^sub_prefix}, 2_000

    # Let the Server finish appending the turn pair.
    Process.sleep(50)

    [{server_pid, _}] = Registry.lookup(agent.registry, {agent_name, :server})
    state = :sys.get_state(server_pid)

    assert [
             %UserMessage{content: pointer},
             %AssistantMessage{content: "delivery handled"}
           ] = state.messages

    assert pointer =~ ~s(<webhook-delivery)
    assert pointer =~ ~s(webhook_id="integration-1")
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
