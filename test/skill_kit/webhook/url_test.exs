defmodule SkillKit.Webhook.UrlTest do
  use ExUnit.Case, async: false

  alias SkillKit.Webhook
  alias SkillKit.Webhook.Url

  setup do
    prior = Application.get_env(:skill_kit, :webhook_base_url)
    on_exit(fn -> Application.put_env(:skill_kit, :webhook_base_url, prior) end)
    :ok
  end

  defp sample(id),
    do: %Webhook{
      id: id,
      agent_name: "a",
      prompt: "",
      verifier: {M, %{}},
      inserted_at: DateTime.utc_now()
    }

  test "builds absolute URL when :webhook_base_url is set" do
    Application.put_env(:skill_kit, :webhook_base_url, "https://example.com/hooks")
    assert Url.url(sample("abc")) == "https://example.com/hooks/abc"
  end

  test "trims trailing slash from base url" do
    Application.put_env(:skill_kit, :webhook_base_url, "https://example.com/hooks/")
    assert Url.url(sample("abc")) == "https://example.com/hooks/abc"
  end

  test "falls back to path-only when no base configured" do
    Application.put_env(:skill_kit, :webhook_base_url, nil)
    assert Url.url(sample("abc")) == "/webhooks/abc"
  end

  test "opt override beats app config" do
    Application.put_env(:skill_kit, :webhook_base_url, "https://a.example.com")

    assert Url.url(sample("abc"), base_url: "https://b.example.com") ==
             "https://b.example.com/abc"
  end
end
