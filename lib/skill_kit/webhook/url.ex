defmodule SkillKit.Webhook.Url do
  @moduledoc """
  Builds externally-visible URLs for webhook registrations.

  By default reads `config :skill_kit, :webhook_base_url`. Hosts can
  override per-call via the `:base_url` option. When neither is set the
  URL is returned path-only (`/webhooks/<id>`), useful for tests and
  relative routing.
  """

  alias SkillKit.Webhook

  @default_path "/webhooks"

  @spec url(Webhook.t(), keyword()) :: String.t()
  def url(%Webhook{id: id}, opts \\ []) do
    join(resolve_base(opts), id)
  end

  defp resolve_base(opts) do
    Keyword.get(opts, :base_url) || Application.get_env(:skill_kit, :webhook_base_url)
  end

  defp join(nil, id), do: "#{@default_path}/#{id}"

  defp join(base, id) when is_binary(base) do
    base |> String.trim_trailing("/") |> Kernel.<>("/#{id}")
  end
end
