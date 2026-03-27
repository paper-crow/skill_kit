defmodule SkillKit.Hooks.Http do
  @moduledoc """
  Hook handler that POSTs hook context as JSON to a URL.

  Response interpretation:
  - 2xx with `{"decision": "deny", "reason": "..."}` → `{:deny, reason}`
  - 2xx with `{"decision": "allow"}` or no decision field → `:ok`
  - Non-2xx → `{:deny, "HTTP hook returned status <code>"}`
  - Connection error → `:ok` (non-blocking, matches Claude Code)
  """

  @behaviour SkillKit.Hooks.Handler

  @impl true
  def execute(%{"url" => url} = config, context) do
    headers = Map.get(config, "headers", %{})
    timeout = Map.get(config, "timeout", 30) * 1000

    case Req.post(url, json: context, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        interpret_response(body)

      {:ok, %{status: status}} ->
        {:deny, "HTTP hook returned status #{status}"}

      {:error, _reason} ->
        :ok
    end
  end

  defp interpret_response(%{"decision" => "deny", "reason" => reason}), do: {:deny, reason}
  defp interpret_response(%{"decision" => "allow"}), do: :ok
  defp interpret_response(_body), do: :ok
end
