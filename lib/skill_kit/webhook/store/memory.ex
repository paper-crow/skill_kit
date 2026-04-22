defmodule SkillKit.Webhook.Store.Memory do
  @moduledoc false
  @behaviour SkillKit.Webhook.Store

  def start_link(opts), do: Agent.start_link(fn -> %{} end, opts)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @impl true
  def put(_config, _webhook), do: :ok

  @impl true
  def get(_config, _id), do: {:error, :not_found}

  @impl true
  def delete(_config, _id), do: :ok

  @impl true
  def list(_config, _filter), do: {:ok, []}
end
