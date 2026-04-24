defmodule SkillKit.Tools.Webhook do
  @moduledoc """
  Kit that lets agents register webhook endpoints via skill activation.

  Host wiring:

      SkillKit.start_agent("agents/support",
        tools: [{SkillKit.Tools.Shell, []}],
        skills: [
          {SkillKit.Tools.Webhook,
            verifiers: %{
              "stripe" => SkillKit.Webhook.Verifier.Stripe,
              "github" => SkillKit.Webhook.Verifier.Github,
              "slack"  => SkillKit.Webhook.Verifier.Slack,
              "none"   => SkillKit.Webhook.Verifier.None
            }}
        ])

  The webhook kit lives in `skills:`, not `tools:`. The parent LLM sees
  `activate_skill(name: "webhook:register" | "webhook:unregister" | "webhook:list")`
  and activates one of the skills. `activate_skill` forks a child agent
  that inherits the parent's `tools:` AND has `SkillKit.Tools.Webhook`
  added as a first-class tool in the child. The child reads the skill
  body and calls the `webhook` tool directly with structured args.

  `load_kits/1`:

  1. Stashes the configured `verifiers` map and agent-scoped
     `supervisor` name into kit + skill `metadata` — flowing through
     `ToolExecution.context` at activation time.
  2. Sets `metadata.tool = __MODULE__` so when this kit is added to the
     child agent's `tools:` list, the Catalog exposes the `webhook`
     tool. (At the parent level this has no effect because the kit is
     in `skills:`, not `tools:`.)
  3. Injects a `:pre_agent` `%Hook{}` onto every skill so
     `SkillKit.Webhook.Lifecycle` attaches the agent to the
     `Webhook.Registry` when it boots.

  `execute/1` dispatches on `input["operation"]`.
  """

  use SkillKit.Kit, name: "webhook"

  alias SkillKit.Hook
  alias SkillKit.ToolExecution
  alias SkillKit.Webhook
  alias SkillKit.Webhook.Lifecycle
  alias SkillKit.Webhook.Url
  alias SkillKit.Webhook.Verifier.Github
  alias SkillKit.Webhook.Verifier.Slack
  alias SkillKit.Webhook.Verifier.Stripe

  @default_verifiers %{
    "stripe" => Stripe,
    "github" => Github,
    "slack" => Slack
  }

  @impl SkillKit.Kit.Provider
  def load_kits(config) do
    {:ok, [kit]} = super(config)
    supervisor = Keyword.get(config, :supervisor, SkillKit.Webhook)
    verifiers = Keyword.get(config, :verifiers, @default_verifiers)

    validate_verifiers!(verifiers)

    hook = lifecycle_hook(supervisor)

    skills =
      Enum.map(kit.skills, fn skill ->
        patch_skill(skill, hook, supervisor, verifiers)
      end)

    metadata =
      Map.merge(kit.metadata, %{
        tool: __MODULE__,
        supervisor: supervisor,
        verifiers: verifiers
      })

    {:ok, [%{kit | skills: skills, metadata: metadata}]}
  end

  @impl SkillKit.Tool
  def definition do
    %SkillKit.Tool{
      name: "webhook",
      description:
        "Register, update, unregister, or list HTTP webhook endpoints bound to this agent. " <>
          "Registered endpoints are hosted by this process; inbound requests are " <>
          "verified and delivered as user messages. Use operation=register to create, " <>
          "operation=update to modify an existing webhook (URL preserved), " <>
          "operation=unregister to delete, operation=list to view.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "operation" => %{
            "type" => "string",
            "enum" => ["register", "update", "unregister", "list"]
          },
          "prompt" => %{
            "type" => "string",
            "description" =>
              "register (required) / update (optional). Plain-English handler brief that becomes " <>
                "the sub-loop's system prompt addition when this webhook fires. The request body " <>
                "+ metadata are available to the receiving agent via the `webhook_inbox` tool."
          },
          "verifier" => %{
            "type" => "object",
            "description" =>
              "register (required) / update (optional). Keys: type (stripe|github|slack), " <>
                "secret_key, optional max_skew.",
            "properties" => %{
              "type" => %{"type" => "string", "enum" => ["stripe", "github", "slack"]},
              "secret_key" => %{"type" => "string"},
              "max_skew" => %{"type" => "integer"}
            },
            "required" => ["type", "secret_key"]
          },
          "idempotency" => %{
            "type" => "object",
            "description" =>
              "register only, optional. Keys: key ({header: ...} or {json_path: $.field}) and ttl."
          },
          "id" => %{
            "type" => "string",
            "description" => "update / unregister. The webhook id returned at registration."
          }
        },
        "required" => ["operation"]
      }
    }
  end

  defp lifecycle_hook(supervisor) do
    %Hook{
      event: :pre_agent,
      matcher: nil,
      handler: {Lifecycle, %{supervisor: supervisor}}
    }
  end

  defp patch_skill(skill, hook, supervisor, verifiers) do
    metadata = Map.merge(skill.metadata, %{supervisor: supervisor, verifiers: verifiers})
    %{skill | hooks: [hook | skill.hooks], metadata: metadata}
  end

  defp validate_verifiers!(verifiers) do
    Enum.each(verifiers, fn {type, module} ->
      Code.ensure_loaded!(module)

      unless function_exported?(module, :verify, 4) do
        raise ArgumentError,
              "verifier #{inspect(module)} for type #{inspect(type)} does not implement " <>
                "SkillKit.Webhook.Verifier (missing verify/4)"
      end
    end)
  end

  # -- Tool callback --------------------------------------------------------

  @impl SkillKit.Tool
  def execute(%ToolExecution{input: %{"operation" => op}} = exec) do
    dispatch(op, exec)
  end

  def execute(%ToolExecution{}), do: {:error, "missing required field: operation"}

  defp dispatch("register", exec), do: register(exec)
  defp dispatch("update", exec), do: update(exec)
  defp dispatch("unregister", exec), do: unregister(exec)
  defp dispatch("list", exec), do: list(exec)
  defp dispatch(op, _exec), do: {:error, "unknown webhook operation: #{inspect(op)}"}

  # -- register -------------------------------------------------------------

  defp register(%ToolExecution{input: input, context: ctx}) do
    case build_webhook(input, ctx) do
      {:ok, webhook} -> persist_and_report(webhook, ctx)
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp build_webhook(input, ctx) do
    with {:ok, prompt} <- require_string(input, "prompt"),
         {:ok, verifier} <- resolve_verifier(input, ctx),
         {:ok, idempotency} <- resolve_idempotency(input) do
      {:ok,
       %Webhook{
         id: generate_id(),
         agent_name: ctx.agent_name,
         prompt: prompt,
         verifier: verifier,
         idempotency: idempotency,
         inserted_at: DateTime.utc_now()
       }}
    end
  end

  defp persist_and_report(%Webhook{} = webhook, ctx) do
    case Webhook.register(webhook, supervisor: ctx.supervisor) do
      :ok -> {:ok, "Webhook registered. URL: " <> Url.url(webhook)}
      {:error, reason} -> {:error, "failed to persist webhook: #{inspect(reason)}"}
    end
  end

  defp require_string(input, key) do
    case Map.get(input, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp resolve_verifier(input, ctx) do
    case Map.get(input, "verifier", %{}) do
      %{"type" => type} = cfg when is_binary(type) -> lookup_verifier(type, cfg, ctx)
      _ -> {:error, {:missing_field, "verifier.type"}}
    end
  end

  defp lookup_verifier(type, cfg, ctx) do
    case Map.get(ctx.verifiers, type) do
      nil -> {:error, {:unknown_verifier, type}}
      module -> build_verifier_binding(module, cfg)
    end
  end

  defp build_verifier_binding(module, cfg) do
    case Map.get(cfg, "secret_key") do
      key when is_binary(key) and byte_size(key) > 0 ->
        {:ok, {module, %{secret_key: key, max_skew: Map.get(cfg, "max_skew", 300)}}}

      _ ->
        {:error, {:missing_field, "verifier.secret_key"}}
    end
  end

  defp resolve_idempotency(input) do
    case Map.get(input, "idempotency") do
      nil -> {:ok, nil}
      %{} = cfg -> normalize_idempotency(cfg)
    end
  end

  defp normalize_idempotency(cfg) do
    case Map.get(cfg, "key") do
      %{"header" => header} when is_binary(header) ->
        {:ok, %{key: %{"header" => header}, ttl: Map.get(cfg, "ttl", 86_400)}}

      %{"json_path" => path} when is_binary(path) ->
        {:ok, %{key: %{"json_path" => path}, ttl: Map.get(cfg, "ttl", 86_400)}}

      _ ->
        {:error, {:invalid, "idempotency.key"}}
    end
  end

  defp generate_id do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp format_error({:missing_field, field}), do: "missing required field: #{field}"

  defp format_error({:unknown_verifier, type}),
    do: "unknown verifier type: #{type}; available types are passed in the agent's kit config"

  defp format_error({:invalid, field}), do: "invalid value for field: #{field}"

  # -- update ---------------------------------------------------------------

  defp update(%ToolExecution{input: %{"id" => id} = input, context: ctx}) when is_binary(id) do
    case Webhook.get(id, supervisor: ctx.supervisor) do
      {:ok, webhook} -> apply_update(webhook, input, ctx)
      {:error, :not_found} -> {:error, "webhook not found: #{id}"}
    end
  end

  defp update(_exec), do: {:error, "missing required field: id"}

  defp apply_update(webhook, input, ctx) do
    with {:ok, prompt} <- updated_prompt(webhook, input),
         {:ok, verifier} <- updated_verifier(webhook, input, ctx) do
      updated = %{webhook | prompt: prompt, verifier: verifier}
      :ok = Webhook.register(updated, supervisor: ctx.supervisor)
      {:ok, "Webhook updated. URL: " <> Url.url(updated)}
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp updated_prompt(webhook, input) do
    case Map.fetch(input, "prompt") do
      :error -> {:ok, webhook.prompt}
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid, "prompt"}}
    end
  end

  defp updated_verifier(webhook, input, ctx) do
    case Map.fetch(input, "verifier") do
      :error -> {:ok, webhook.verifier}
      {:ok, _value} -> resolve_verifier(input, ctx)
    end
  end

  # -- unregister -----------------------------------------------------------

  defp unregister(%ToolExecution{input: %{"id" => id}, context: ctx}) when is_binary(id) do
    case Webhook.get(id, supervisor: ctx.supervisor) do
      {:ok, %Webhook{}} ->
        :ok = Webhook.unregister(id, supervisor: ctx.supervisor)
        {:ok, "OK"}

      {:error, :not_found} ->
        {:ok, "Webhook not found"}
    end
  end

  defp unregister(_exec), do: {:error, "missing required field: id"}

  # -- list -----------------------------------------------------------------

  defp list(%ToolExecution{context: ctx}) do
    {:ok, webhooks} =
      Webhook.list(%{agent_name: ctx.agent_name}, supervisor: ctx.supervisor)

    encoded =
      webhooks
      |> Enum.map(&summary/1)
      |> Jason.encode!()

    {:ok, encoded}
  end

  defp summary(%Webhook{} = webhook) do
    {verifier_mod, _cfg} = webhook.verifier

    %{
      id: webhook.id,
      url: Url.url(webhook),
      prompt: webhook.prompt,
      verifier: %{type: to_string(verifier_mod)},
      inserted_at: DateTime.to_iso8601(webhook.inserted_at)
    }
  end
end
