defmodule SkillKit.Storage.Memory do
  @moduledoc """
  In-memory storage provider backed by an `Agent` process.

  Designed for testing. State is a flat map where paths are keys and
  values are `{:file, binary()}` or `:dir`.
  """

  @behaviour SkillKit.Storage
  use Agent

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, opts)
  end

  @impl true
  def read(path) do
    case Agent.get(__MODULE__, &Map.get(&1, path)) do
      {:file, content} -> {:ok, content}
      _ -> {:error, :enoent}
    end
  end

  @impl true
  def put(path, content) do
    binary = coerce_binary(content)
    Agent.update(__MODULE__, &Map.put(&1, path, {:file, binary}))
    :ok
  end

  @impl true
  def delete(path) do
    case Agent.get(__MODULE__, &Map.get(&1, path)) do
      nil ->
        {:error, :enoent}

      _ ->
        Agent.update(__MODULE__, &Map.delete(&1, path))
        :ok
    end
  end

  @impl true
  def delete_all(path) do
    prefix = path <> "/"

    removed =
      Agent.get_and_update(__MODULE__, fn state ->
        {removed, kept} =
          Enum.split_with(state, fn {key, _val} ->
            key == path or String.starts_with?(key, prefix)
          end)

        removed_paths = Enum.map(removed, &elem(&1, 0))
        {removed_paths, Map.new(kept)}
      end)

    {:ok, removed}
  end

  @impl true
  def list(path) do
    state = Agent.get(__MODULE__, & &1)
    prefix = path <> "/"

    has_dir = Map.get(state, path) == :dir

    children =
      state
      |> Enum.filter(fn {key, _val} -> String.starts_with?(key, prefix) end)
      |> Enum.map(fn {key, _val} ->
        key
        |> String.trim_leading(prefix)
        |> String.split("/", parts: 2)
        |> hd()
      end)
      |> Enum.uniq()

    if has_dir or children != [] do
      {:ok, children}
    else
      {:error, :enoent}
    end
  end

  @impl true
  def exists?(path) do
    state = Agent.get(__MODULE__, & &1)
    prefix = path <> "/"

    Map.has_key?(state, path) or
      Enum.any?(state, fn {key, _val} -> String.starts_with?(key, prefix) end)
  end

  @impl true
  def dir?(path) do
    state = Agent.get(__MODULE__, & &1)
    prefix = path <> "/"

    Map.get(state, path) == :dir or
      Enum.any?(state, fn {key, _val} ->
        key != path and String.starts_with?(key, prefix)
      end)
  end

  @impl true
  def ensure_dir(path) do
    all_dirs =
      path
      |> String.split("/")
      |> Enum.scan(&(&2 <> "/" <> &1))

    Agent.update(__MODULE__, fn state ->
      Enum.reduce(all_dirs, state, &Map.put_new(&2, &1, :dir))
    end)

    :ok
  end

  @impl true
  def delete_dir(path) do
    state = Agent.get(__MODULE__, & &1)
    prefix = path <> "/"

    has_children =
      Enum.any?(state, fn {key, _val} ->
        key != path and String.starts_with?(key, prefix)
      end)

    cond do
      has_children ->
        {:error, :eexist}

      Map.get(state, path) == :dir ->
        Agent.update(__MODULE__, &Map.delete(&1, path))
        :ok

      true ->
        {:error, :enoent}
    end
  end

  defp coerce_binary(content) when is_list(content), do: IO.iodata_to_binary(content)
  defp coerce_binary(content), do: content
end
