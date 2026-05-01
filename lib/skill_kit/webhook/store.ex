defmodule SkillKit.Webhook.Store do
  @moduledoc false
  @callback put(config :: keyword(), webhook :: SkillKit.Webhook.t()) :: :ok | {:error, term()}
  @callback get(config :: keyword(), id :: String.t()) ::
              {:ok, SkillKit.Webhook.t()} | {:error, :not_found}
  @callback delete(config :: keyword(), id :: String.t()) :: :ok
  @callback list(config :: keyword(), filter :: map()) :: {:ok, [SkillKit.Webhook.t()]}
end
