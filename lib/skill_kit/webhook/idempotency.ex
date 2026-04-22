defmodule SkillKit.Webhook.Idempotency do
  @moduledoc false
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(_opts), do: {:ok, %{}}
end
