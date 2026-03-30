defmodule SkillKit.Kit.GitHub.Cache do
  @moduledoc """
  Manages the local disk cache for downloaded GitHub repositories.

  Tarballs are extracted to `{cache_dir}/{owner}/{repo}/{ref}/`.
  The top-level directory in the tarball (GitHub adds a `owner-repo-sha/` prefix)
  is stripped so the contents are placed directly in the cache path.
  """

  alias SkillKit.Kit.GitHub.Ref

  require Logger

  @spec extract(binary(), Ref.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def extract(tarball_data, %Ref{} = ref, cache_dir) do
    base_dir = kit_dir(ref, cache_dir)
    File.mkdir_p!(base_dir)

    with {:ok, files} <- decompress_and_list(tarball_data),
         :ok <- write_stripped_files(files, base_dir) do
      resolve_kit_dir(base_dir, ref)
    end
  end

  @spec exists?(Ref.t(), Path.t()) :: boolean()
  def exists?(%Ref{} = ref, cache_dir) do
    dir = kit_dir(ref, cache_dir)
    File.dir?(dir)
  end

  @spec kit_dir(Ref.t(), Path.t()) :: Path.t()
  def kit_dir(%Ref{owner: owner, repo: repo, ref: ref}, cache_dir) do
    Path.join([cache_dir, owner, repo, ref || "default"])
  end

  @spec list_cached(Path.t()) :: [%{owner: String.t(), repo: String.t(), ref: String.t()}]
  def list_cached(cache_dir) do
    case File.ls(cache_dir) do
      {:ok, owners} ->
        Enum.flat_map(owners, &list_owner_repos(cache_dir, &1))

      {:error, :enoent} ->
        []
    end
  end

  @spec remove(Ref.t(), Path.t()) :: :ok
  def remove(%Ref{} = ref, cache_dir) do
    dir = kit_dir(ref, cache_dir)
    remove_and_cleanup(dir, cache_dir)
  end

  defp remove_and_cleanup(dir, cache_dir) do
    if File.dir?(dir) do
      File.rm_rf!(dir)
      cleanup_empty_parents(Path.dirname(dir), cache_dir)
    end

    :ok
  end

  defp cleanup_empty_parents(dir, cache_dir) when dir == cache_dir, do: :ok

  defp cleanup_empty_parents(dir, cache_dir) do
    case File.ls(dir) do
      {:ok, []} ->
        File.rmdir(dir)
        cleanup_empty_parents(Path.dirname(dir), cache_dir)

      _ ->
        :ok
    end
  end

  defp decompress_and_list(tarball_data) do
    tar_data = :zlib.gunzip(tarball_data)
    :erl_tar.extract({:binary, tar_data}, [:memory])
  end

  defp write_stripped_files(files, base_dir) do
    Enum.each(files, &write_stripped_file(&1, base_dir))
    :ok
  end

  defp write_stripped_file({path, content}, base_dir) do
    stripped = strip_top_level(to_string(path))
    dest = Path.expand(Path.join(base_dir, stripped))
    safe_base = Path.expand(base_dir)

    if String.starts_with?(dest, safe_base <> "/") do
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, content)
    else
      Logger.warning("Skipping tarball entry with path traversal: #{path}")
    end
  end

  defp strip_top_level(path) do
    case String.split(path, "/", parts: 2) do
      [_top_level, rest] -> rest
      [single] -> single
    end
  end

  defp resolve_kit_dir(base_dir, %Ref{path: nil}), do: {:ok, base_dir}
  defp resolve_kit_dir(base_dir, %Ref{path: path}), do: {:ok, Path.join(base_dir, path)}

  defp list_owner_repos(cache_dir, owner) do
    owner_dir = Path.join(cache_dir, owner)

    case File.ls(owner_dir) do
      {:ok, repos} ->
        Enum.flat_map(repos, &list_repo_refs(cache_dir, owner, &1))

      {:error, _} ->
        []
    end
  end

  defp list_repo_refs(cache_dir, owner, repo) do
    repo_dir = Path.join([cache_dir, owner, repo])

    case File.ls(repo_dir) do
      {:ok, refs} ->
        refs
        |> Enum.filter(&File.dir?(Path.join(repo_dir, &1)))
        |> Enum.map(&%{owner: owner, repo: repo, ref: &1})

      {:error, _} ->
        []
    end
  end
end
