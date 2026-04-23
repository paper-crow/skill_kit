defmodule SkillKit.Webhook.FixturesTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook.Verifier.Github
  alias SkillKit.Webhook.Verifier.Slack
  alias SkillKit.Webhook.Verifier.Stripe

  setup :verify_on_exit!

  @github_secret "ghs_fixture_secret"
  @stripe_secret "whsec_fixture_secret"
  @slack_secret "slk_fixture_secret"

  defp agent, do: %SkAgent{name: "a", description: "", system_prompt: ""}

  defp load_fixture(relpath) do
    body = File.read!("test/fixtures/webhooks/#{relpath}.json")

    headers =
      "test/fixtures/webhooks/#{relpath}.headers"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [name, value] = String.split(line, ": ", parts: 2)
        {String.downcase(name), value}
      end)

    {body, headers}
  end

  defp conn_with(body, headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/") |> Plug.Conn.assign(:raw_body, body), fn {k,
                                                                                              v},
                                                                                             acc ->
      Plug.Conn.put_req_header(acc, k, v)
    end)
  end

  @tag :external_fixture
  test "github push fixture verifies under the captured secret" do
    stub(SkillKit.CredentialProvider.Mock, :fetch, fn _tool, _agent, "GH" ->
      {:ok, @github_secret}
    end)

    {body, headers} = load_fixture("github/push")
    conn = conn_with(body, headers)
    assert :ok = Github.verify(body, conn, %{secret_key: "GH"}, agent())
  end

  @tag :external_fixture
  test "stripe charge fixture verifies with wide skew" do
    stub(SkillKit.CredentialProvider.Mock, :fetch, fn _tool, _agent, "ST" ->
      {:ok, @stripe_secret}
    end)

    {body, headers} = load_fixture("stripe/charge_succeeded")
    conn = conn_with(body, headers)
    # Historical fixture — 10 year skew tolerance
    assert :ok = Stripe.verify(body, conn, %{secret_key: "ST", max_skew: 315_360_000}, agent())
  end

  @tag :external_fixture
  test "slack app_mention fixture verifies with wide skew" do
    stub(SkillKit.CredentialProvider.Mock, :fetch, fn _tool, _agent, "SL" ->
      {:ok, @slack_secret}
    end)

    {body, headers} = load_fixture("slack/app_mention")
    conn = conn_with(body, headers)
    assert :ok = Slack.verify(body, conn, %{secret_key: "SL", max_skew: 315_360_000}, agent())
  end
end
