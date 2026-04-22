defmodule SkillKit.Webhook.Store.Memory do
  @moduledoc false
  @behaviour SkillKit.Webhook.Store
  use Agent

  def start_link(opts), do: Agent.start_link(fn -> %{} end, opts)

  @impl true
  def put(_config, _webhook), do: :ok

  @impl true
  def get(_config, _id), do: {:error, :not_found}

  @impl true
  def delete(_config, _id), do: :ok

  @impl true
  def list(_config, _filter), do: {:ok, []}
end
