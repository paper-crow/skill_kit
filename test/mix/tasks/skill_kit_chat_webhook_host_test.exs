defmodule Mix.Tasks.SkillKit.Chat.WebhookHostTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SkillKit.Chat.WebhookHost
  alias SkillKit.Webhook.Inbox.Memory, as: InboxMemory
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor

  setup do
    # WebhookHost forwards to SkillKit.Webhook.Plug with default opts, so
    # the supervisor must be registered under the default name.
    {:ok, _pid} = WebhookSupervisor.start_link(inbox: {InboxMemory, [dispatch: :none]})
    :ok
  end

  test "returns 404 when the webhook id is unknown" do
    conn = Plug.Test.conn(:post, "/missing", "")
    result = WebhookHost.call(conn, WebhookHost.init([]))
    assert result.status == 404
  end
end
