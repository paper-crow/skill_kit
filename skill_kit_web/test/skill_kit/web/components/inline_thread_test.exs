defmodule SkillKit.Web.Components.InlineThreadTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias SkillKit.Web.Components.InlineThread

  test "renders thread with messages" do
    thread = %{
      selection_text: "Sessions are stored server-side",
      messages: [
        %{role: :user, content: "What storage backend?"},
        %{role: :assistant, content: "ETS would be simplest."}
      ],
      streaming_text: nil,
      top: 200,
      left: 300
    }

    html = render_component(&InlineThread.inline_thread/1, thread: thread)
    assert html =~ "Sessions are stored server-side"
    assert html =~ "What storage backend?"
    assert html =~ "ETS would be simplest"
  end

  test "renders input field" do
    thread = %{
      selection_text: "some text",
      messages: [],
      streaming_text: nil,
      top: 100,
      left: 200
    }

    html = render_component(&InlineThread.inline_thread/1, thread: thread)
    assert html =~ "Reply"
  end

  test "not rendered when thread is nil" do
    html = render_component(&InlineThread.inline_thread/1, thread: nil)
    refute html =~ "Reply"
  end

  test "shows streaming text with cursor" do
    thread = %{
      selection_text: "some text",
      messages: [],
      streaming_text: "I think",
      top: 100,
      left: 200
    }

    html = render_component(&InlineThread.inline_thread/1, thread: thread)
    assert html =~ "I think"
  end
end
