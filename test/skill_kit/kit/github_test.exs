defmodule SkillKit.Kit.GitHubTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.GitHub
  alias SkillKit.Skill

  setup do
    cache_dir =
      Path.join(
        System.tmp_dir!(),
        "skill_kit_github_test_#{:erlang.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(cache_dir) end)

    %{cache_dir: cache_dir}
  end

  # -------------------------------------------------------------------
  # list_kits/1 — empty cache
  # -------------------------------------------------------------------

  describe "list_kits/1 with empty cache" do
    test "returns only the built-in github kit", %{cache_dir: cache_dir} do
      config = [allowed_sources: "*", cache_dir: cache_dir]

      assert {:ok, [kit]} = GitHub.list_kits(config)
      assert kit.name == "github"
      assert length(kit.skills) == 3

      skill_names = Enum.map(kit.skills, & &1.name)
      assert "github:import" in skill_names
      assert "github:list" in skill_names
      assert "github:remove" in skill_names
    end
  end

  # -------------------------------------------------------------------
  # list_kits/1 — with cached repos
  # -------------------------------------------------------------------

  describe "list_kits/1 with cached repos" do
    test "returns built-in kit plus cached repo kits", %{cache_dir: cache_dir} do
      populate_cache(cache_dir, "owner", "repo", "main")
      config = [allowed_sources: "*", cache_dir: cache_dir]

      assert {:ok, kits} = GitHub.list_kits(config)
      kit_names = Enum.map(kits, & &1.name)

      assert "github" in kit_names
      assert "owner/repo@main" in kit_names
    end

    test "cached kit contains skills loaded by Kit.Local", %{cache_dir: cache_dir} do
      populate_cache(cache_dir, "owner", "repo", "main")
      config = [allowed_sources: "*", cache_dir: cache_dir]

      {:ok, kits} = GitHub.list_kits(config)
      repo_kit = Enum.find(kits, &(&1.name == "owner/repo@main"))
      skill_names = Enum.map(repo_kit.skills, & &1.name)

      assert "test:greet" in skill_names
    end

    test "default ref uses owner/repo as kit name", %{cache_dir: cache_dir} do
      populate_cache(cache_dir, "owner", "repo", "default")
      config = [allowed_sources: "*", cache_dir: cache_dir]

      {:ok, kits} = GitHub.list_kits(config)
      kit_names = Enum.map(kits, & &1.name)

      assert "owner/repo" in kit_names
    end

    test "non-default ref uses owner/repo@ref as kit name", %{cache_dir: cache_dir} do
      populate_cache(cache_dir, "owner", "repo", "v2.0")
      config = [allowed_sources: "*", cache_dir: cache_dir]

      {:ok, kits} = GitHub.list_kits(config)
      kit_names = Enum.map(kits, & &1.name)

      assert "owner/repo@v2.0" in kit_names
    end
  end

  # -------------------------------------------------------------------
  # get_kit/2
  # -------------------------------------------------------------------

  describe "get_kit/2" do
    test "returns the built-in github kit", %{cache_dir: cache_dir} do
      config = [allowed_sources: "*", cache_dir: cache_dir]

      assert {:ok, kit} = GitHub.get_kit(config, "github")
      assert kit.name == "github"
    end

    test "returns a cached repo kit", %{cache_dir: cache_dir} do
      populate_cache(cache_dir, "owner", "repo", "main")
      config = [allowed_sources: "*", cache_dir: cache_dir]

      assert {:ok, kit} = GitHub.get_kit(config, "owner/repo@main")
      assert kit.name == "owner/repo@main"
    end

    test "returns not_found for unknown kit", %{cache_dir: cache_dir} do
      config = [allowed_sources: "*", cache_dir: cache_dir]

      assert {:error, :not_found} = GitHub.get_kit(config, "nonexistent")
    end
  end

  # -------------------------------------------------------------------
  # resolve_token/1
  # -------------------------------------------------------------------

  describe "resolve_token/1" do
    test "returns nil when not configured" do
      assert GitHub.resolve_token(nil) == nil
    end

    test "returns string token directly" do
      assert GitHub.resolve_token("my-token") == "my-token"
    end

    test "resolves {:env, var} tuple" do
      System.put_env("TEST_GH_TOKEN", "from-env")
      on_exit(fn -> System.delete_env("TEST_GH_TOKEN") end)

      assert GitHub.resolve_token({:env, "TEST_GH_TOKEN"}) == "from-env"
    end

    test "returns nil for missing env var" do
      assert GitHub.resolve_token({:env, "NONEXISTENT_VAR_12345"}) == nil
    end
  end

  # -------------------------------------------------------------------
  # builtin skill metadata carries all provider config
  # -------------------------------------------------------------------

  describe "builtin skill metadata" do
    test "carries cache_dir, allowed_sources, and api_token from config", %{cache_dir: cache_dir} do
      config = [
        allowed_sources: "paper-crow/*",
        cache_dir: cache_dir,
        api_token: "test-token"
      ]

      {:ok, [kit]} = GitHub.list_kits(config)
      import_skill = Enum.find(kit.skills, &(&1.name == "github:import"))

      assert import_skill.metadata["cache_dir"] == cache_dir
      assert import_skill.metadata["allowed_sources"] == "paper-crow/*"
      assert import_skill.metadata["api_token"] == "test-token"
    end
  end

  # -------------------------------------------------------------------
  # execute/1 — github:import
  # -------------------------------------------------------------------

  describe "execute/1 — github:import" do
    test "downloads and caches a repo", %{cache_dir: cache_dir} do
      bypass = Bypass.open()
      tarball = create_test_tarball()

      Bypass.expect_once(bypass, "GET", "/repos/owner/repo/tarball/main", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/gzip")
        |> Plug.Conn.resp(200, tarball)
      end)

      execution =
        build_execution("github:import", %{
          "source" => "owner/repo@main",
          "cache_dir" => cache_dir,
          "allowed_sources" => "*",
          "base_url" => "http://localhost:#{bypass.port}"
        })

      assert {:ok, result} = GitHub.execute(execution)
      assert result =~ "Imported"
      assert result =~ "test:greet"
    end

    test "rejects disallowed source", %{cache_dir: cache_dir} do
      execution =
        build_execution("github:import", %{
          "source" => "evil-corp/malware",
          "cache_dir" => cache_dir,
          "allowed_sources" => "paper-crow/*"
        })

      assert {:error, message} = GitHub.execute(execution)
      assert message =~ "not in allowed_sources"
    end

    test "skips download when already cached", %{cache_dir: cache_dir} do
      populate_cache(cache_dir, "owner", "repo", "main")

      execution =
        build_execution("github:import", %{
          "source" => "owner/repo@main",
          "cache_dir" => cache_dir,
          "allowed_sources" => "*"
        })

      assert {:ok, result} = GitHub.execute(execution)
      assert result =~ "already cached"
    end

    test "returns error for not found repo", %{cache_dir: cache_dir} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/repos/owner/repo/tarball/main", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
      end)

      execution =
        build_execution("github:import", %{
          "source" => "owner/repo@main",
          "cache_dir" => cache_dir,
          "allowed_sources" => "*",
          "base_url" => "http://localhost:#{bypass.port}"
        })

      assert {:error, message} = GitHub.execute(execution)
      assert message =~ "not found"
    end

    test "reads allowed_sources from skill metadata when not in input", %{cache_dir: cache_dir} do
      meta = %{
        "cache_dir" => cache_dir,
        "allowed_sources" => "paper-crow/*",
        "api_token" => nil
      }

      exec = %SkillKit.ToolExecution{
        skill: %Skill{name: "github:import", tool: GitHub, metadata: meta},
        tool: GitHub,
        input: %{"source" => "evil-corp/malware"},
        context: %{},
        status: :pending
      }

      assert {:error, message} = GitHub.execute(exec)
      assert message =~ "not in allowed_sources"
    end
  end

  # -------------------------------------------------------------------
  # execute/1 — github:list
  # -------------------------------------------------------------------

  describe "execute/1 — github:list" do
    test "lists cached repos with skills", %{cache_dir: cache_dir} do
      populate_cache(cache_dir, "owner", "repo", "main")

      execution = build_execution("github:list", %{"cache_dir" => cache_dir})

      assert {:ok, result} = GitHub.execute(execution)
      assert result =~ "owner/repo@main"
      assert result =~ "test:greet"
    end

    test "reports empty when no repos cached", %{cache_dir: cache_dir} do
      execution = build_execution("github:list", %{"cache_dir" => cache_dir})

      assert {:ok, result} = GitHub.execute(execution)
      assert result =~ "No GitHub repositories"
    end

    test "reads cache_dir from skill metadata when not in input", %{cache_dir: cache_dir} do
      populate_cache(cache_dir, "owner", "repo", "main")

      meta = %{"cache_dir" => cache_dir, "allowed_sources" => "*", "api_token" => nil}

      exec = %SkillKit.ToolExecution{
        skill: %Skill{name: "github:list", tool: GitHub, metadata: meta},
        tool: GitHub,
        input: %{},
        context: %{},
        status: :pending
      }

      assert {:ok, result} = GitHub.execute(exec)
      assert result =~ "owner/repo@main"
    end
  end

  # -------------------------------------------------------------------
  # execute/1 — github:remove
  # -------------------------------------------------------------------

  describe "execute/1 — github:remove" do
    test "removes a cached repo", %{cache_dir: cache_dir} do
      populate_cache(cache_dir, "owner", "repo", "main")

      execution =
        build_execution("github:remove", %{
          "source" => "owner/repo@main",
          "cache_dir" => cache_dir
        })

      assert {:ok, result} = GitHub.execute(execution)
      assert result =~ "Removed"

      refute File.dir?(Path.join([cache_dir, "owner", "repo", "main"]))
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp populate_cache(cache_dir, owner, repo, ref) do
    kit_dir = Path.join([cache_dir, owner, repo, ref])
    skill_dir = Path.join([kit_dir, "skills", "greet"])
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: "test:greet"
    description: "A greeting skill"
    ---
    Say hello to the user.
    """)
  end

  defp build_execution(skill_name, input) do
    meta = Map.take(input, ["cache_dir", "allowed_sources", "api_token"])

    %SkillKit.ToolExecution{
      skill: %Skill{name: skill_name, tool: GitHub, metadata: meta},
      tool: GitHub,
      input: input,
      context: %{},
      status: :pending
    }
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

    tmp =
      Path.join(
        System.tmp_dir!(),
        "test_tarball_#{:erlang.unique_integer([:positive])}.tar"
      )

    :ok = :erl_tar.create(to_charlist(tmp), files, [:write])
    tar_data = File.read!(tmp)
    File.rm!(tmp)
    :zlib.gzip(tar_data)
  end
end
