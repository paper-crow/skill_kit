defmodule SkillKit.Web.ChatSmokeTest do
  use SkillKitWeb.ConnCase
  import Phoenix.LiveViewTest

  alias SkillKit.Types.UserMessage
  alias SkillKit.Web.ConversationStore
  alias SkillKit.Web.EditorScope

  @tmp_dir "test/tmp/chat_smoke_test"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "welcome.md"), "# Welcome\n\nWhat are you building?")
    Application.put_env(:skill_kit_web, :docs_root, @tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
  end

  test "full flow: browse doc, send message", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Welcome"
    assert html =~ "Type your message"

    view |> form("form", %{message: "Hello agent"}) |> render_submit()
    assert render(view) =~ "Hello agent"
  end

  test "ConversationStore round-trips messages" do
    dir = Path.join(@tmp_dir, "conversations")
    File.mkdir_p!(dir)

    messages = [%UserMessage{content: "Test message"}]
    assert :ok = ConversationStore.save("test-conv", messages, dir: dir)

    assert {:ok, [%UserMessage{content: "Test message"}]} =
             ConversationStore.load("test-conv", dir: dir)
  end

  test "EditorScope implements Scope protocol" do
    scope = %EditorScope{project_root: "/test", docs_root: "/test/guides"}
    assert ["docs:*", "build:*"] = SkillKit.Scope.permissions(scope)

    assert {:ok, "/test"} =
             SkillKit.Scope.resolve(scope, "PROJECT_ROOT", %{agent: "a", skill: "s"})
  end
end
