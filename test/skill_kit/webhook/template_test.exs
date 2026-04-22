defmodule SkillKit.Webhook.TemplateTest do
  use ExUnit.Case, async: true

  alias SkillKit.Webhook.Template

  describe "render_prompt/2" do
    test "substitutes $WEBHOOK_BODY" do
      assert Template.render_prompt("got: $WEBHOOK_BODY", %{body: "payload"}) ==
               "got: payload"
    end

    test "substitutes $WEBHOOK_METHOD and $WEBHOOK_QUERY" do
      assert Template.render_prompt(
               "$WEBHOOK_METHOD $WEBHOOK_QUERY",
               %{method: "POST", query: "{\"q\":1}"}
             ) == "POST {\"q\":1}"
    end

    test "$WEBHOOK_HEADERS gets JSON-encoded header map" do
      headers = [{"x-test", "value"}]

      rendered =
        Template.render_prompt(
          "headers=$WEBHOOK_HEADERS",
          %{headers: Jason.encode!(Map.new(headers))}
        )

      assert rendered == ~s(headers={"x-test":"value"})
    end

    test "missing tokens render as empty string" do
      assert Template.render_prompt("x=$WEBHOOK_BODY y=$WEBHOOK_METHOD", %{}) == "x= y="
    end

    test "unrecognized tokens pass through unchanged" do
      assert Template.render_prompt("$OTHER $WEBHOOK_BODY", %{body: "x"}) == "$OTHER x"
    end
  end

  describe "render_signing/3" do
    test "substitutes $BODY and $TIMESTAMP" do
      assert Template.render_signing("$TIMESTAMP.$BODY", "payload", "1234") ==
               "1234.payload"
    end

    test "handles literal prefixes" do
      assert Template.render_signing("v0:$TIMESTAMP:$BODY", "body", "1") == "v0:1:body"
    end

    test "returns template unchanged when it has no tokens" do
      assert Template.render_signing("$BODY", "x", "0") == "x"
    end
  end
end
