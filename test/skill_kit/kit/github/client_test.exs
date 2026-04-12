defmodule SkillKit.Kit.GitHub.ClientTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.GitHub.Client

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  describe "download_tarball/2" do
    test "downloads tarball for public repo", %{bypass: bypass, base_url: base_url} do
      tarball_content = create_test_tarball()

      Bypass.expect_once(bypass, "GET", "/repos/owner/repo/tarball/main", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/gzip")
        |> Plug.Conn.resp(200, tarball_content)
      end)

      ref = %SkillKit.Kit.GitHub.Ref{owner: "owner", repo: "repo", ref: "main"}
      assert {:ok, body} = Client.download_tarball(ref, base_url: base_url)
      assert is_binary(body)
    end

    test "uses default branch when ref is nil", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/repo/tarball/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/gzip")
        |> Plug.Conn.resp(200, "fake-tarball")
      end)

      ref = %SkillKit.Kit.GitHub.Ref{owner: "owner", repo: "repo", ref: nil}
      assert {:ok, _body} = Client.download_tarball(ref, base_url: base_url)
    end

    test "includes auth header when token provided", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/repo/tarball/main", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer my-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/gzip")
        |> Plug.Conn.resp(200, "fake-tarball")
      end)

      ref = %SkillKit.Kit.GitHub.Ref{owner: "owner", repo: "repo", ref: "main"}
      assert {:ok, _} = Client.download_tarball(ref, base_url: base_url, token: "my-token")
    end

    test "returns error for 404", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/repo/tarball/main", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
      end)

      ref = %SkillKit.Kit.GitHub.Ref{owner: "owner", repo: "repo", ref: "main"}
      assert {:error, :not_found} = Client.download_tarball(ref, base_url: base_url)
    end

    test "returns error for 403 rate limit", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/repo/tarball/main", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.resp(403, ~s({"message": "API rate limit exceeded"}))
      end)

      ref = %SkillKit.Kit.GitHub.Ref{owner: "owner", repo: "repo", ref: "main"}
      assert {:error, :rate_limited} = Client.download_tarball(ref, base_url: base_url)
    end
  end

  defp create_test_tarball do
    files = [
      {~c"owner-repo-abc123/skills/greet/SKILL.md",
       """
       ---
       name: "test:greet"
       description: "A greeting skill"
       ---
       Say hello to the user.
       """}
    ]

    path = Path.join(System.tmp_dir!(), "test_#{System.unique_integer([:positive])}.tar")
    :ok = :erl_tar.create(String.to_charlist(path), files, [])
    tar_data = File.read!(path)
    File.rm!(path)
    :zlib.gzip(tar_data)
  end
end
