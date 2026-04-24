defmodule SkillKit.Tools.WebhookInboxTest do
  use ExUnit.Case, async: false

  alias SkillKit.ToolExecution
  alias SkillKit.Tools.WebhookInbox
  alias SkillKit.Webhook.Inbox.Memory

  setup do
    name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Memory.start_link(name: name, max_deliveries: 10, ttl_ms: :timer.hours(1), dispatch: :none)

    {:ok, inbox: name}
  end

  defp put_delivery(inbox, id, body) do
    Memory.put(inbox, %{
      agent: %SkillKit.AgentRef{name: "agent-1", registry: :r, supervisor_pid: nil},
      prompt: "p",
      delivery: %{
        id: id,
        webhook_id: "wh_1",
        agent_name: "agent-1",
        received_at: DateTime.utc_now(),
        method: "POST",
        headers: %{"x-github-event" => "push"},
        query: %{},
        body: body
      }
    })
  end

  defp exec(input, ctx) do
    %ToolExecution{tool: WebhookInbox, input: input, context: ctx}
  end

  defp ctx(inbox) do
    %{inbox_module: Memory, inbox: inbox, agent_name: "agent-1"}
  end

  describe "definition/0" do
    test "returns a valid Tool struct" do
      tool = WebhookInbox.definition()
      assert tool.name == "webhook_inbox"
      assert is_binary(tool.description)
      assert is_map(tool.input_schema)
      assert tool.input_schema["properties"]["operation"]["enum"] == ~w(list summary read delete)
    end
  end

  describe "list" do
    test "returns JSON array of summaries for the calling agent", %{inbox: inbox} do
      put_delivery(inbox, "a", ~s({"x":1}))
      put_delivery(inbox, "b", ~s({"x":2}))

      assert {:ok, reply} = WebhookInbox.execute(exec(%{"operation" => "list"}, ctx(inbox)))
      assert {:ok, list} = Jason.decode(reply)
      assert length(list) == 2
      assert Enum.map(list, & &1["id"]) == ["b", "a"]
    end
  end

  describe "summary" do
    test "returns JSON shape tree for the given id", %{inbox: inbox} do
      put_delivery(inbox, "s1", ~s({"ref":"main","commits":[{"id":"c1"}]}))

      assert {:ok, reply} =
               WebhookInbox.execute(exec(%{"operation" => "summary", "id" => "s1"}, ctx(inbox)))

      assert {:ok, summary} = Jason.decode(reply)
      assert summary["id"] == "s1"
      assert summary["method"] == "POST"
      assert summary["body"]["type"] == "object"
    end

    test "missing id returns error", %{inbox: inbox} do
      assert {:error, msg} = WebhookInbox.execute(exec(%{"operation" => "summary"}, ctx(inbox)))
      assert msg =~ "id"
    end

    test "unknown id returns error", %{inbox: inbox} do
      assert {:error, msg} =
               WebhookInbox.execute(
                 exec(%{"operation" => "summary", "id" => "ghost"}, ctx(inbox))
               )

      assert msg =~ "not found"
    end
  end

  describe "read" do
    test "returns the sliced value by selector", %{inbox: inbox} do
      put_delivery(inbox, "r1", ~s({"ref":"refs/heads/main"}))

      input = %{"operation" => "read", "id" => "r1", "selector" => "body.ref"}
      assert {:ok, reply} = WebhookInbox.execute(exec(input, ctx(inbox)))
      assert reply =~ "refs/heads/main"
    end

    test "passes opts through to the Inbox read call", %{inbox: inbox} do
      commits_json = Jason.encode!(%{"commits" => Enum.map(1..5, &%{"msg" => "c#{&1}"})})
      put_delivery(inbox, "r2", commits_json)

      input = %{
        "operation" => "read",
        "id" => "r2",
        "selector" => "body.commits[].msg",
        "offset" => 1,
        "limit" => 2
      }

      assert {:ok, reply} = WebhookInbox.execute(exec(input, ctx(inbox)))
      assert {:ok, decoded} = Jason.decode(reply)
      assert decoded["value"] == ["c2", "c3"]
      assert decoded["total"] == 5
    end

    test "invalid selector returns error", %{inbox: inbox} do
      put_delivery(inbox, "r3", ~s({"x":1}))

      input = %{"operation" => "read", "id" => "r3", "selector" => "body.nope.deep"}
      assert {:error, msg} = WebhookInbox.execute(exec(input, ctx(inbox)))
      assert msg =~ "selector"
    end

    test "unknown id returns error", %{inbox: inbox} do
      input = %{"operation" => "read", "id" => "ghost", "selector" => "body"}
      assert {:error, msg} = WebhookInbox.execute(exec(input, ctx(inbox)))
      assert msg =~ "not found"
    end
  end

  describe "delete" do
    test "evicts a delivery", %{inbox: inbox} do
      put_delivery(inbox, "d1", ~s({"x":1}))

      assert {:ok, reply} =
               WebhookInbox.execute(exec(%{"operation" => "delete", "id" => "d1"}, ctx(inbox)))

      assert reply == "OK"

      assert {:error, _} =
               WebhookInbox.execute(exec(%{"operation" => "summary", "id" => "d1"}, ctx(inbox)))
    end
  end

  describe "errors" do
    test "missing operation", %{inbox: inbox} do
      assert {:error, msg} = WebhookInbox.execute(exec(%{}, ctx(inbox)))
      assert msg =~ "operation"
    end

    test "unknown operation", %{inbox: inbox} do
      assert {:error, msg} =
               WebhookInbox.execute(exec(%{"operation" => "ghost"}, ctx(inbox)))

      assert msg =~ "unknown operation"
    end
  end
end
