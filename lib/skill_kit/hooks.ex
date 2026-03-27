defmodule SkillKit.Hooks do
  @moduledoc """
  Dispatches lifecycle hooks at agent boundaries.

  Two public functions:

  - `call/4` — wraps a boundary in a telemetry span with pre/post hook
    dispatch. Blocks for a decision from pre-event hooks.
  - `cast/3` — fires a single hook event, fire-and-forget.

  Hook events are derived from boundary names: `call(catalog, :tool_use, ...)`
  fires `:pre_tool_use` before and `:post_tool_use` after the callback.
  """

  alias SkillKit.Catalog
  alias SkillKit.Hook
  alias SkillKit.Telemetry

  @type decision :: :ok | {:deny, term()} | {:pending, term()}

  @doc """
  Wraps a boundary in a telemetry span with pre/post hook dispatch.

  Derives hook events from the boundary name: `pre_<boundary>` before
  executing `func`, `post_<boundary>` after. The telemetry span uses
  the boundary name directly.

  `func` must return `{result, post_context}` where `post_context` is
  passed to post-event hooks.
  """
  @spec call(GenServer.server(), atom(), map(), (-> {term(), map()})) :: term()
  def call(catalog, boundary, context, func) do
    pre_event = :"pre_#{boundary}"
    post_event = :"post_#{boundary}"

    Telemetry.span([boundary], context, fn ->
      case fire(catalog, pre_event, context) do
        :ok ->
          {result, post_context} = func.()
          notify(catalog, post_event, post_context)
          {result, %{}, %{}}

        {:deny, reason} ->
          {{:deny, reason}, %{}, %{status: :denied}}

        {:pending, state} ->
          {{:pending, state}, %{}, %{status: :suspended}}
      end
    end)
  end

  @doc """
  Fires a single hook event, fire-and-forget.
  """
  @spec cast(GenServer.server(), Hook.event(), map()) :: :ok
  def cast(catalog, event, context) do
    notify(catalog, event, context)
  end

  # -- Private: hook dispatch -----------------------------------------------

  defp fire(catalog, event, context) do
    catalog
    |> Catalog.list_hooks(event)
    |> filter_by_matcher(event, context)
    |> reduce_until_denied(context)
  end

  defp notify(catalog, event, context) do
    catalog
    |> Catalog.list_hooks(event)
    |> filter_by_matcher(event, context)
    |> Enum.each(&invoke_handler(&1.handler, context))

    :ok
  end

  defp reduce_until_denied([], _context), do: :ok

  defp reduce_until_denied([hook | rest], context) do
    case invoke_handler(hook.handler, context) do
      :ok -> reduce_until_denied(rest, context)
      {:deny, _reason} = deny -> deny
      {:pending, _state} = pending -> pending
    end
  end

  defp invoke_handler({mod, config}, context) when is_map(config) do
    apply(mod, :execute, [config, context])
  end

  defp invoke_handler(fun, context) when is_function(fun, 1), do: fun.(context)

  defp invoke_handler({mod, fun, args}, context) do
    apply(mod, fun, [context | args])
  end

  defp filter_by_matcher(hooks, event, context) do
    match_target = match_target_for(event, context)
    Enum.filter(hooks, &matches?(&1, match_target))
  end

  defp matches?(%Hook{matcher: nil}, _target), do: true
  defp matches?(%Hook{matcher: regex}, target), do: Regex.match?(regex, target)

  defp match_target_for(event, context) when event in [:pre_tool_use, :post_tool_use] do
    tool_match_target(Map.get(context, :tool))
  end

  defp match_target_for(event, context) when event in [:pre_subagent, :post_subagent] do
    Map.get(context, :name, Map.get(context, :agent_name, ""))
  end

  defp match_target_for(event, context)
       when event in [:pre_skill_activation, :post_skill_activation] do
    skill_match_target(Map.get(context, :skill))
  end

  defp match_target_for(event, context)
       when event in [:pre_llm_request, :post_llm_request] do
    Map.get(context, :model, Map.get(context, :agent_name, ""))
  end

  defp match_target_for(_event, context), do: Map.get(context, :agent_name, "")

  defp tool_match_target(nil), do: ""
  defp tool_match_target(tool), do: tool |> Module.split() |> List.last()

  defp skill_match_target(nil), do: ""
  defp skill_match_target(skill), do: skill.name
end
