defmodule SkillKit.Kit.GitHub do
  @moduledoc """
  Provider that imports skills from GitHub repositories at runtime.

  Downloads repos as tarballs, caches them to disk, and delegates to
  `Kit.Local` for parsing. Ships built-in skills (`github:import`,
  `github:list`, `github:remove`) so agents can self-extend.

  ## Configuration

      {SkillKit.Kit.GitHub,
        allowed_sources: "*",
        api_token: {:env, "GITHUB_TOKEN"},
        cache_dir: "/tmp/skill_kit/github"
      }
  """

  @behaviour SkillKit.Kit.Provider
  @behaviour SkillKit.Tool

  alias SkillKit.Kit
  alias SkillKit.Kit.GitHub.Cache
  alias SkillKit.Kit.GitHub.Client
  alias SkillKit.Kit.GitHub.Ref
  alias SkillKit.Kit.Local
  alias SkillKit.Skill

  require Logger

  @default_cache_dir Path.join(System.tmp_dir!(), "skill_kit/github")

  # -------------------------------------------------------------------
  # Provider callbacks
  # -------------------------------------------------------------------

  @impl SkillKit.Kit.Provider
  def list_kits(config) do
    cache_dir = Keyword.get(config, :cache_dir, @default_cache_dir)
    cached_kits = load_cached_kits(cache_dir)
    {:ok, [builtin_kit(config) | cached_kits]}
  end

  @impl SkillKit.Kit.Provider
  def get_kit(config, "github"), do: {:ok, builtin_kit(config)}

  def get_kit(config, name) do
    case list_kits(config) do
      {:ok, kits} -> find_kit(kits, name)
      error -> error
    end
  end

  # -------------------------------------------------------------------
  # Token resolution
  # -------------------------------------------------------------------

  @spec resolve_token(nil | String.t() | {:env, String.t()}) :: String.t() | nil
  def resolve_token(nil), do: nil
  def resolve_token(token) when is_binary(token), do: token
  def resolve_token({:env, var}) when is_binary(var), do: System.get_env(var)

  # -------------------------------------------------------------------
  # Tool callbacks
  # -------------------------------------------------------------------

  @impl SkillKit.Tool
  def execute(%SkillKit.ToolExecution{skill: %{name: "github:import"}} = exec) do
    execute_import(exec)
  end

  def execute(%SkillKit.ToolExecution{skill: %{name: "github:list"}} = exec) do
    execute_list(exec)
  end

  def execute(%SkillKit.ToolExecution{skill: %{name: "github:remove"}} = exec) do
    execute_remove(exec)
  end

  @impl SkillKit.Tool
  def resume(_execution, _state, :approved), do: {:error, :not_resumable}
  def resume(_execution, _state, {:denied, reason}), do: {:error, {:denied, reason}}

  @impl SkillKit.Tool
  def definition do
    %SkillKit.Tool{
      name: "github",
      description: "Import skills from GitHub repositories",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "source" => %{
            "type" => "string",
            "description" => "GitHub reference: owner/repo[/path][@ref]"
          }
        }
      }
    }
  end

  # -------------------------------------------------------------------
  # Built-in kit
  # -------------------------------------------------------------------

  defp builtin_kit(config) do
    %Kit{
      name: "github",
      skills: builtin_skills(config),
      metadata: %{tool: __MODULE__}
    }
  end

  defp builtin_skills(config) do
    meta = %{
      "cache_dir" => Keyword.get(config, :cache_dir, @default_cache_dir),
      "allowed_sources" => Keyword.get(config, :allowed_sources, "*"),
      "api_token" => Keyword.get(config, :api_token)
    }

    [
      %Skill{
        name: "github:import",
        namespace: "github",
        description:
          "Import skills from a GitHub repository. " <>
            "Provide a source like 'owner/repo', 'owner/repo@tag', or 'owner/repo/path@branch'.",
        body: nil,
        tool: __MODULE__,
        metadata: meta
      },
      %Skill{
        name: "github:list",
        namespace: "github",
        description: "List all GitHub repositories currently imported and their skills.",
        body: nil,
        tool: __MODULE__,
        metadata: meta
      },
      %Skill{
        name: "github:remove",
        namespace: "github",
        description: "Remove a previously imported GitHub repository from the local cache.",
        body: nil,
        tool: __MODULE__,
        metadata: meta
      }
    ]
  end

  # -------------------------------------------------------------------
  # Cache scanning
  # -------------------------------------------------------------------

  defp load_cached_kits(cache_dir) do
    cache_dir
    |> Cache.list_cached()
    |> Enum.flat_map(&load_cached_kit(cache_dir, &1))
  end

  defp load_cached_kit(cache_dir, %{owner: owner, repo: repo, ref: ref}) do
    dir = Path.join([cache_dir, owner, repo, ref])

    case Local.list_kits(dir: dir) do
      {:ok, [kit]} ->
        name = format_kit_name(owner, repo, ref)
        [%{kit | name: name}]

      {:ok, []} ->
        []

      {:error, _} ->
        []
    end
  end

  defp format_kit_name(owner, repo, "default"), do: "#{owner}/#{repo}"
  defp format_kit_name(owner, repo, ref), do: "#{owner}/#{repo}@#{ref}"

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp find_kit(kits, name) do
    case Enum.find(kits, &(&1.name == name)) do
      nil -> {:error, :not_found}
      kit -> {:ok, kit}
    end
  end

  # -------------------------------------------------------------------
  # Import execution
  # -------------------------------------------------------------------

  defp execute_import(%SkillKit.ToolExecution{skill: skill, input: input}) do
    meta = skill.metadata
    source = Map.fetch!(input, "source")
    cache_dir = Map.get(input, "cache_dir", meta["cache_dir"] || @default_cache_dir)
    allowed = Map.get(input, "allowed_sources", meta["allowed_sources"] || "*")
    token = Map.get(input, "api_token", meta["api_token"])
    base_url = Map.get(input, "base_url")

    with {:ok, ref} <- Ref.parse(source),
         :ok <- check_allowed(ref, allowed) do
      fetch_or_use_cache(ref, cache_dir, token, base_url)
    end
  end

  defp check_allowed(ref, allowed) do
    allowed_list = normalize_allowed(allowed)

    if Ref.allowed?(ref, allowed_list) do
      :ok
    else
      {:error, "Source '#{Ref.display_name(ref)}' not in allowed_sources"}
    end
  end

  defp normalize_allowed(allowed) when is_list(allowed), do: allowed
  defp normalize_allowed(allowed) when is_binary(allowed), do: [allowed]

  defp fetch_or_use_cache(ref, cache_dir, token, base_url) do
    if Cache.exists?(ref, cache_dir) do
      {:ok, "#{Ref.display_name(ref)} already cached. Skills are available."}
    else
      download_and_cache(ref, cache_dir, token, base_url)
    end
  end

  defp download_and_cache(ref, cache_dir, token, base_url) do
    client_opts =
      [token: resolve_token(token)]
      |> maybe_add_base_url(base_url)

    case Client.download_tarball(ref, client_opts) do
      {:ok, tarball} ->
        extract_and_report(tarball, ref, cache_dir)

      {:error, :not_found} ->
        {:error, "Repository #{Ref.display_name(ref)} not found on GitHub."}

      {:error, :rate_limited} ->
        {:error, "GitHub API rate limit exceeded. Configure an api_token for higher limits."}

      {:error, :forbidden} ->
        {:error, "Access denied for #{Ref.display_name(ref)}. Check your api_token."}

      {:error, reason} ->
        {:error, "Failed to download #{Ref.display_name(ref)}: #{inspect(reason)}"}
    end
  end

  defp extract_and_report(tarball, ref, cache_dir) do
    case Cache.extract(tarball, ref, cache_dir) do
      {:ok, kit_dir} ->
        skills = discover_skill_names(kit_dir)
        format_import_result(ref, skills)

      {:error, reason} ->
        {:error, "Failed to extract #{Ref.display_name(ref)}: #{inspect(reason)}"}
    end
  end

  defp discover_skill_names(kit_dir) do
    case Local.list_kits(dir: kit_dir) do
      {:ok, [kit]} -> Enum.map(kit.skills, & &1.name)
      _ -> []
    end
  end

  defp format_import_result(ref, []) do
    {:ok,
     "Imported #{Ref.display_name(ref)} — 0 skills found. " <>
       "Ensure the repo follows the skills/*/SKILL.md convention."}
  end

  defp format_import_result(ref, skill_names) do
    names = Enum.join(skill_names, ", ")
    {:ok, "Imported #{Ref.display_name(ref)} — #{length(skill_names)} skill(s): #{names}"}
  end

  defp maybe_add_base_url(opts, nil), do: opts
  defp maybe_add_base_url(opts, url), do: Keyword.put(opts, :base_url, url)

  # -------------------------------------------------------------------
  # List execution
  # -------------------------------------------------------------------

  defp execute_list(%SkillKit.ToolExecution{skill: skill, input: input}) do
    meta = skill.metadata
    cache_dir = Map.get(input, "cache_dir", meta["cache_dir"] || @default_cache_dir)
    cached = Cache.list_cached(cache_dir)

    if cached == [] do
      {:ok, "No GitHub repositories imported yet."}
    else
      lines = Enum.map(cached, &format_cached_entry(cache_dir, &1))
      {:ok, "Imported repositories:\n#{Enum.join(lines, "\n")}"}
    end
  end

  defp format_cached_entry(cache_dir, %{owner: owner, repo: repo, ref: ref}) do
    kit_dir = Path.join([cache_dir, owner, repo, ref])
    skills = discover_skill_names(kit_dir)
    name = format_kit_name(owner, repo, ref)
    "- #{name}: #{Enum.join(skills, ", ")}"
  end

  # -------------------------------------------------------------------
  # Remove execution
  # -------------------------------------------------------------------

  defp execute_remove(%SkillKit.ToolExecution{skill: skill, input: input}) do
    meta = skill.metadata
    source = Map.fetch!(input, "source")
    cache_dir = Map.get(input, "cache_dir", meta["cache_dir"] || @default_cache_dir)

    case Ref.parse(source) do
      {:ok, ref} ->
        Cache.remove(ref, cache_dir)
        {:ok, "Removed #{Ref.display_name(ref)} from cache."}

      {:error, _} ->
        {:error, "Invalid source reference: #{source}"}
    end
  end
end
