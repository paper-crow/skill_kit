defmodule SkillKit.Webhook.SupervisorTest do
  use ExUnit.Case, async: false

  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor

  test "starts with default name" do
    {:ok, pid} = WebhookSupervisor.start_link([])
    assert Process.alive?(pid)
    assert Process.whereis(SkillKit.Webhook) == pid
    :ok = Supervisor.stop(pid)
  end

  test "starts with custom name" do
    name = :"#{__MODULE__}_custom"
    {:ok, pid} = WebhookSupervisor.start_link(name: name)
    assert Process.whereis(name) == pid
    :ok = Supervisor.stop(pid)
  end

  test "child_spec/1 uses the configured name as id" do
    spec = WebhookSupervisor.child_spec(name: SomeName)
    assert spec.id == SomeName
  end
end
