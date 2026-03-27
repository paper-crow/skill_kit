defmodule SkillKit.Web.RouterTest do
  use SkillKitWeb.ConnCase

  test "GET / renders the editor", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "skill-kit-editor"
  end
end
