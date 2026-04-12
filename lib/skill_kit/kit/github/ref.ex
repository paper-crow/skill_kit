defmodule SkillKit.Kit.GitHub.Ref do
  @moduledoc """
  Parses GitHub repository references in the format `owner/repo[/path][@ref]`.
  """

  @type t :: %__MODULE__{
          owner: String.t(),
          repo: String.t(),
          path: String.t() | nil,
          ref: String.t() | nil
        }

  @enforce_keys [:owner, :repo]
  defstruct [:owner, :repo, :path, :ref]

  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_reference}
  def parse(source) when is_binary(source) do
    parts = split_ref(source)
    split_segments(parts)
  end

  def parse(_), do: {:error, :invalid_reference}

  @spec cache_key(t()) :: String.t()
  def cache_key(%__MODULE__{owner: owner, repo: repo, ref: ref}) do
    "#{owner}/#{repo}/#{ref || "default"}"
  end

  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{owner: owner, repo: repo, ref: nil}) do
    "#{owner}/#{repo}"
  end

  def display_name(%__MODULE__{owner: owner, repo: repo, ref: ref}) do
    "#{owner}/#{repo}@#{ref}"
  end

  @spec allowed?(t(), String.t() | [String.t()]) :: boolean()
  def allowed?(%__MODULE__{} = ref, patterns) when is_list(patterns) do
    Enum.any?(patterns, &allowed?(ref, &1))
  end

  def allowed?(%__MODULE__{}, "*"), do: true

  def allowed?(%__MODULE__{owner: owner, repo: repo}, pattern) when is_binary(pattern) do
    match_pattern(owner, repo, String.split(pattern, "/", parts: 2))
  end

  defp match_pattern(owner, _repo, [pat_owner, "*"]), do: owner == pat_owner

  defp match_pattern(owner, repo, [pat_owner, pat_repo]),
    do: owner == pat_owner and repo == pat_repo

  defp match_pattern(_owner, _repo, _), do: false

  defp split_ref(source) do
    case String.split(source, "@", parts: 2) do
      [path_part, ref] when ref != "" -> {path_part, ref}
      [path_part] -> {path_part, nil}
      _ -> {"", nil}
    end
  end

  defp split_segments({"", _ref}), do: {:error, :invalid_reference}

  defp split_segments({path_part, ref}) do
    segments = String.split(path_part, "/")
    build_ref(segments, ref)
  end

  defp build_ref([owner, repo | rest], ref) when owner != "" and repo != "" do
    path = if rest == [], do: nil, else: Enum.join(rest, "/")
    {:ok, %__MODULE__{owner: owner, repo: repo, path: path, ref: ref}}
  end

  defp build_ref(_, _), do: {:error, :invalid_reference}
end
