defmodule SkillKit.Kit.GitHub.Client do
  @moduledoc """
  HTTP client for downloading tarballs from GitHub's API.
  """

  alias SkillKit.Kit.GitHub.Ref

  @default_base_url "https://api.github.com"

  @spec download_tarball(Ref.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def download_tarball(%Ref{owner: owner, repo: repo, ref: ref}, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    token = Keyword.get(opts, :token)
    url = "#{base_url}/repos/#{owner}/#{repo}/tarball/#{ref || ""}"
    headers = build_headers(token)

    case Req.get(url, headers: headers, redirect: true, max_redirects: 5, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 403, headers: resp_headers}} ->
        classify_forbidden(resp_headers)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp build_headers(nil), do: [{"accept", "application/vnd.github+json"}]

  defp build_headers(token) do
    [{"accept", "application/vnd.github+json"}, {"authorization", "Bearer #{token}"}]
  end

  defp classify_forbidden(headers) do
    remaining = Map.get(headers, "x-ratelimit-remaining")

    if remaining == ["0"] do
      {:error, :rate_limited}
    else
      {:error, :forbidden}
    end
  end
end
