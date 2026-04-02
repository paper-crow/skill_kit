defmodule SkillKit.Web.RouterTest do
  use SkillKitWeb.ConnCase

  @tmp_dir Path.expand("../../tmp/router_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "welcome.md"), "# Welcome")
    Application.put_env(:skill_kit_web, :docs_root, @tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
  end

  test "GET / renders the editor", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "skill-kit-editor"
  end

  test "GET / redirects to /setup when no documents", %{conn: conn} do
    empty_dir = Path.join(@tmp_dir, "empty")
    File.mkdir_p!(empty_dir)
    Application.put_env(:skill_kit_web, :docs_root, empty_dir)

    conn = get(conn, "/")
    assert redirected_to(conn) == "/setup"
  end
end
