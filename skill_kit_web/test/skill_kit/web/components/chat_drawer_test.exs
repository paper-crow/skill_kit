defmodule SkillKit.Web.Components.ChatDrawerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SkillKit.Web.Components.ChatDrawer

  test "renders chat messages" do
    messages = [
      %{role: :assistant, content: "Hello! How can I help?"},
      %{role: :user, content: "Tell me about the auth system"}
    ]

    html =
      render_component(&ChatDrawer.chat_drawer/1,
        messages: messages,
        streaming_text: nil,
        open: true
      )

    assert html =~ "Hello! How can I help?"
    assert html =~ "Tell me about the auth system"
  end

  test "renders streaming text" do
    html =
      render_component(&ChatDrawer.chat_drawer/1,
        messages: [],
        streaming_text: "I'm currently thinking about",
        open: true
      )

    assert html =~ "currently thinking about"
  end

  test "hidden when not open" do
    html =
      render_component(&ChatDrawer.chat_drawer/1,
        messages: [],
        streaming_text: nil,
        open: false
      )

    assert html =~ "hidden"
  end

  test "renders input field" do
    html =
      render_component(&ChatDrawer.chat_drawer/1,
        messages: [],
        streaming_text: nil,
        open: true
      )

    assert html =~ "Type your message"
  end
end
