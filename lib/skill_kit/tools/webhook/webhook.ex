defmodule SkillKit.Tools.Webhook do
  @moduledoc """
  Kit that lets agents register webhook endpoints via skill activation.

  ## Host wiring

      SkillKit.start_agent("agents/support",
        tools: [{SkillKit.Tools.Shell, []}],
        skills: [
          {SkillKit.Tools.Webhook,
            github:  [secret_key: "GITHUB_WEBHOOK_SECRET"],
            stripe:  [secret_key: "STRIPE_WEBHOOK_SECRET", max_skew: 600],
            slack:   [secret_key: "SLACK_WEBHOOK_SECRET"],
            allow_unsigned: true}
        ])

  Each configured provider binds its signing secret to the corresponding
  register skill. `allow_unsigned: true` additionally loads the
  `webhook:unsigned` skill for ad-hoc endpoints protected only by URL
  secrecy.

  ## Skill surface

  Always loaded (vendor register + management):

    * `webhook:github`, `webhook:stripe`, `webhook:slack` — signed
      vendor skills. Each stores the webhook with its verifier module
      pre-bound. If the host did not configure a vendor's secret,
      registration still succeeds (the LLM sees no error) but the
      resulting webhook's secret_key is `nil`; at on-hit time the
      verifier returns `:misconfigured` and the Plug responds 500. This
      design prevents the LLM from drifting to the unsigned skill as a
      fallback when a signed vendor appears unavailable.

    * `webhook:update`, `webhook:unregister`, `webhook:list` — vendor-
      agnostic management. Update is prompt-only; to rotate a verifier
      secret, unregister + re-register.

  Opt-in:

    * `webhook:unsigned` — loaded only when `allow_unsigned: true`. The
      SKILL.md calls out when NOT to use it.

  ## Runtime

  When a register skill is activated, its metadata (`verifier_module`,
  `secret_key`, `max_skew`, `supervisor`) flows into the tool's
  `ToolExecution.context`. The `register` op reads those directly — it
  does NOT accept a `verifier` field from the LLM's tool input. The
  LLM has no capability to choose credential names or verifier modules.
  """

  use SkillKit.Kit, name: "webhook"

  alias SkillKit.Hook
  alias SkillKit.ToolExecution
  alias SkillKit.Webhook
  alias SkillKit.Webhook.Lifecycle
  alias SkillKit.Webhook.Url
  alias SkillKit.Webhook.Verifier.Github
  alias SkillKit.Webhook.Verifier.None
  alias SkillKit.Webhook.Verifier.Slack
  alias SkillKit.Webhook.Verifier.Stripe

  @provider_modules %{
    github: Github,
    stripe: Stripe,
    slack: Slack
  }

  @provider_skill_names Map.new(@provider_modules, fn {atom, _} -> {"webhook:#{atom}", atom} end)

  @default_max_skew 300

  @impl SkillKit.Kit.Provider
  def load_kits(config) do
    {:ok, [kit]} = super(config)
    supervisor = Keyword.get(config, :supervisor, SkillKit.Webhook)
    allow_unsigned = Keyword.get(config, :allow_unsigned, false)

    vendor_bindings = build_vendor_bindings(config)
    unsigned_binding = build_unsigned_binding(allow_unsigned)

    hook = lifecycle_hook(supervisor)

    skills =
      kit.skills
      |> filter_skills(allow_unsigned)
      |> Enum.map(&patch_skill(&1, hook, supervisor, vendor_bindings, unsigned_binding))

    metadata =
      Map.merge(kit.metadata, %{
        tool: __MODULE__,
        supervisor: supervisor
      })

    {:ok, [%{kit | skills: skills, metadata: metadata}]}
  end

  @impl SkillKit.Tool
  def definition do
    %SkillKit.Tool{
      name: "webhook",
      description:
        "Register, update, unregister, or list HTTP webhook endpoints bound to this agent. " <>
          "Each vendor has its own register skill (webhook:github, webhook:stripe, " <>
          "webhook:slack, webhook:unsigned). Update, unregister, and list are " <>
          "vendor-agnostic.",
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
              "register (required) / update (optional). Plain-English handler brief " <>
                "that becomes the sub-loop's system prompt addition when this webhook " <>
                "fires. The framework teaches the sub-loop how to read payloads via " <>
                "the webhook_inbox tool — write the prompt as intent, not as a " <>
                "template."
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

  # -- skill filtering + binding --------------------------------------------

  defp filter_skills(skills, allow_unsigned) do
    case allow_unsigned do
      true -> skills
      false -> Enum.reject(skills, &(&1.name == "webhook:unsigned"))
    end
  end

  defp build_vendor_bindings(config) do
    Enum.reduce(@provider_modules, %{}, fn {atom, module}, acc ->
      binding = vendor_binding(module, Keyword.get(config, atom))
      Map.put(acc, atom, binding)
    end)
  end

  defp vendor_binding(module, nil) do
    %{verifier_module: module, secret_key: nil, max_skew: @default_max_skew}
  end

  defp vendor_binding(module, opts) when is_list(opts) do
    secret_key = Keyword.get(opts, :secret_key)

    unless is_binary(secret_key) do
      raise ArgumentError,
            "webhook provider config must include :secret_key as a string, got: #{inspect(opts)}"
    end

    %{
      verifier_module: module,
      secret_key: secret_key,
      max_skew: Keyword.get(opts, :max_skew, @default_max_skew)
    }
  end

  defp vendor_binding(_module, other) do
    raise ArgumentError,
          "webhook provider config must be a keyword list, got: #{inspect(other)}"
  end

  defp build_unsigned_binding(true) do
    %{verifier_module: None, secret_key: nil, max_skew: @default_max_skew}
  end

  defp build_unsigned_binding(false), do: nil

  defp lifecycle_hook(supervisor) do
    %Hook{
      event: :pre_agent,
      matcher: nil,
      handler: {Lifecycle, %{supervisor: supervisor}}
    }
  end

  defp patch_skill(%{name: name} = skill, hook, supervisor, vendor_bindings, unsigned_binding) do
    base = skill_metadata(name, vendor_bindings, unsigned_binding)
    extra = Map.put(base, :supervisor, supervisor)

    metadata = Map.merge(skill.metadata, extra)
    %{skill | hooks: [hook | skill.hooks], metadata: metadata}
  end

  defp skill_metadata(name, vendor_bindings, unsigned_binding) do
    case Map.get(@provider_skill_names, name) do
      nil -> skill_metadata_for(name, unsigned_binding)
      vendor -> Map.fetch!(vendor_bindings, vendor)
    end
  end

  defp skill_metadata_for("webhook:unsigned", binding) when is_map(binding), do: binding
  defp skill_metadata_for(_name, _binding), do: %{}

  # -- Tool dispatch -------------------------------------------------------

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

  # -- register ------------------------------------------------------------

  defp register(%ToolExecution{input: input, context: ctx}) do
    case build_webhook(input, ctx) do
      {:ok, webhook} -> persist_and_report(webhook, ctx)
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp build_webhook(input, ctx) do
    with {:ok, prompt} <- require_string(input, "prompt"),
         {:ok, verifier} <- resolve_verifier_from_ctx(ctx),
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

  defp resolve_verifier_from_ctx(%{verifier_module: None}) do
    {:ok, {None, %{}}}
  end

  defp resolve_verifier_from_ctx(%{verifier_module: module, secret_key: secret, max_skew: skew})
       when is_atom(module) do
    config = %{secret_key: secret, max_skew: skew}
    {:ok, {module, config}}
  end

  defp resolve_verifier_from_ctx(_ctx), do: {:error, {:invalid, "verifier context"}}

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
    Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  defp format_error({:missing_field, field}), do: "missing required field: #{field}"
  defp format_error({:invalid, field}), do: "invalid value for field: #{field}"

  # -- update (prompt-only) ------------------------------------------------

  defp update(%ToolExecution{input: %{"id" => id} = input, context: ctx}) when is_binary(id) do
    dispatch_update(Webhook.get(id, supervisor: ctx.supervisor), id, input, ctx)
  end

  defp update(_exec), do: {:error, "missing required field: id"}

  defp dispatch_update({:ok, webhook}, _id, input, ctx) do
    case updated_prompt(webhook, input) do
      {:ok, prompt} ->
        updated = %{webhook | prompt: prompt}
        :ok = Webhook.register(updated, supervisor: ctx.supervisor)
        {:ok, "Webhook updated. URL: " <> Url.url(updated)}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp dispatch_update({:error, :not_found}, id, _input, _ctx) do
    {:error, "webhook not found: #{id}"}
  end

  defp updated_prompt(webhook, input) do
    case Map.fetch(input, "prompt") do
      :error -> {:ok, webhook.prompt}
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid, "prompt"}}
    end
  end

  # -- unregister ----------------------------------------------------------

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

  # -- list ----------------------------------------------------------------

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
