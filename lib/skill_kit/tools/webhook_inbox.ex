defmodule SkillKit.Tools.WebhookInbox do
  @moduledoc """
  Tool for reading webhook deliveries that have landed in the calling
  agent's inbox.

  Injected into the sub-loop's tool set by `SkillKit.Webhook.Message.send_event_opts/3`
  during webhook delivery processing; not part of the agent's main
  conversation tool list. Dispatches to whatever `SkillKit.Webhook.Inbox`
  implementation the host has configured — Memory by default, swappable.

  ## Context

  The tool expects the following keys in its `%ToolExecution{}.context`:

    * `:inbox_module` — the module implementing `SkillKit.Webhook.Inbox`
    * `:inbox` — the registered inbox handle (name / pid / via-tuple)
    * `:agent_name` — the calling agent's name; used to scope reads so
      agent A can't read agent B's deliveries

  These are populated by `Message.send_event_opts/3` from the
  `inbox_ref` the Inbox impl passes when calling `Inbox.dispatch/2`.

  ## Operations

    * `list` — recent delivery summaries for this agent (newest first)
    * `summary` — structural shape tree for one delivery (by id)
    * `read` — sliced value from one delivery (by id + selector)
    * `delete` — evict one delivery (by id)

  ## Read slicing

  See `SkillKit.Webhook.Inbox` module docs for selector syntax and
  slicing opts (`offset`, `limit`, `offset_bytes`, `limit_bytes`,
  `line_start`, `line_end`, `as`).
  """

  @behaviour SkillKit.Tool

  alias SkillKit.ToolExecution

  @operations ~w(list summary read delete)

  @impl SkillKit.Tool
  def definition do
    %SkillKit.Tool{
      name: "webhook_inbox",
      description: """
      Read webhook deliveries that have landed in this agent's inbox.
      Use operation=list to see recent deliveries, operation=summary to inspect
      one delivery's structure (types, sizes, keys) without reading leaf values,
      operation=read to get a specific slice by selector, operation=delete to evict.
      """,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "operation" => %{"type" => "string", "enum" => @operations},
          "id" => %{
            "type" => "string",
            "description" => """
            Delivery id. Required for summary, read, delete. Obtain from
            the <webhook-delivery id="..."/> tag in the inbound user message
            or from a prior list call.
            """
          },
          "selector" => %{
            "type" => "string",
            "description" => """
            read only. Dot-notation path into the delivery: body.field,
            body.arr[0].field, body.arr[].field (array projection),
            headers.x-header-name, headers, query, method.
            """
          },
          "offset" => %{
            "type" => "integer",
            "description" => "read only. Array offset when selector resolves to a list."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "read only. Array limit when selector resolves to a list."
          },
          "offset_bytes" => %{
            "type" => "integer",
            "description" => "read only. Byte offset when selector resolves to a string/binary."
          },
          "limit_bytes" => %{
            "type" => "integer",
            "description" => """
            read only. Byte cap on the serialized result. Final safety net;
            truncated results include total so you can paginate.
            """
          },
          "line_start" => %{
            "type" => "integer",
            "description" =>
              "read only. First line (0-indexed) when selector resolves to multi-line text."
          },
          "line_end" => %{
            "type" => "integer",
            "description" =>
              "read only. Last line (exclusive) when selector resolves to multi-line text."
          },
          "as" => %{
            "type" => "string",
            "enum" => ~w(json text base64),
            "description" =>
              "read only. Output format: json (default for structured), text, base64."
          }
        },
        "required" => ["operation"]
      }
    }
  end

  @impl SkillKit.Tool
  def execute(%ToolExecution{input: input, context: ctx}) do
    dispatch(Map.get(input, "operation"), input, ctx)
  end

  @impl SkillKit.Tool
  def resume(_exec, _state, _decision), do: {:error, "resume not supported"}

  # -- operation dispatch --------------------------------------------------

  defp dispatch(nil, _input, _ctx), do: {:error, "missing required field: operation"}

  defp dispatch("list", _input, ctx) do
    {:ok, summaries} = apply(ctx.inbox_module, :list, [ctx.inbox, ctx.agent_name, []])
    {:ok, Jason.encode!(summaries)}
  end

  defp dispatch("summary", input, ctx) do
    with_id(input, fn id ->
      format_summary(apply(ctx.inbox_module, :summary, [ctx.inbox, ctx.agent_name, id]))
    end)
  end

  defp dispatch("read", input, ctx) do
    with_id(input, fn id ->
      opts = read_opts(input)
      format_read(apply(ctx.inbox_module, :read, [ctx.inbox, ctx.agent_name, id, opts]))
    end)
  end

  defp dispatch("delete", input, ctx) do
    with_id(input, fn id ->
      :ok = apply(ctx.inbox_module, :delete, [ctx.inbox, ctx.agent_name, id])
      {:ok, "OK"}
    end)
  end

  defp dispatch(other, _input, _ctx), do: {:error, "unknown operation: #{other}"}

  # -- helpers -------------------------------------------------------------

  defp with_id(input, fun) do
    case Map.get(input, "id") do
      id when is_binary(id) and id != "" -> fun.(id)
      _ -> {:error, "missing required field: id"}
    end
  end

  defp format_summary({:ok, summary}), do: {:ok, Jason.encode!(summary)}
  defp format_summary({:error, :not_found}), do: {:error, "delivery not found"}

  defp format_read({:ok, result}), do: {:ok, Jason.encode!(result)}
  defp format_read({:error, :not_found}), do: {:error, "delivery not found"}
  defp format_read({:error, :invalid_selector}), do: {:error, "invalid selector"}

  defp read_opts(input) do
    [
      :selector,
      :offset,
      :limit,
      :offset_bytes,
      :limit_bytes,
      :line_start,
      :line_end,
      :as
    ]
    |> Enum.map(&{&1, fetch_input(input, to_string(&1))})
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp fetch_input(input, key) do
    case Map.get(input, key) do
      "" -> nil
      val -> val
    end
  end
end
