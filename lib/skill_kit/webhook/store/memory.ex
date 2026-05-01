defmodule SkillKit.Webhook.Store.Memory do
  @moduledoc """
  In-memory webhook store backed by an `Agent` process holding a map.

  Content is lost on BEAM restart. Intended for dev, tests, and single-node
  deployments where re-registering webhooks after restart is acceptable.
  Use a durable backend implementing `SkillKit.Webhook.Store` in production.

  ## Config

      {:ok, pid} = SkillKit.Webhook.Store.Memory.start_link()
      config = [pid: pid]
      :ok = SkillKit.Webhook.Store.Memory.put(config, webhook)
  """

  @behaviour SkillKit.Webhook.Store
  use Agent

  alias SkillKit.Webhook

  @doc "Starts the backing `Agent` process."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts)
  end

  @impl true
  def put(config, %Webhook{id: id} = webhook) do
    pid = resolve_pid(config)
    Agent.update(pid, &Map.put(&1, id, webhook))
    :ok
  end

  @impl true
  def get(config, id) do
    pid = resolve_pid(config)
    fetch(Agent.get(pid, &Map.get(&1, id)))
  end

  @impl true
  def delete(config, id) do
    pid = resolve_pid(config)
    Agent.update(pid, &Map.delete(&1, id))
    :ok
  end

  @impl true
  def list(config, filter) do
    pid = resolve_pid(config)

    webhooks =
      pid
      |> Agent.get(&Map.values/1)
      |> Enum.filter(&matches?(&1, filter))

    {:ok, webhooks}
  end

  defp fetch(nil), do: {:error, :not_found}
  defp fetch(%Webhook{} = webhook), do: {:ok, webhook}

  defp matches?(%Webhook{} = webhook, filter) do
    Enum.all?(filter, fn {key, value} -> Map.get(webhook, key) == value end)
  end

  defp resolve_pid(config) do
    case Keyword.fetch(config, :pid) do
      {:ok, pid} -> pid
      :error -> Keyword.fetch!(config, :name)
    end
  end
end
