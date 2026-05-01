defmodule SkillKit.Webhook.TemplateTest do
  use ExUnit.Case, async: true

  alias SkillKit.Webhook.Template

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
