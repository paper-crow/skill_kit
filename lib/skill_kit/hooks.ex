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

  require Logger

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
  @spec call(GenServer.server() | SkillKit.Agent.t(), atom(), map(), (-> {term(), map()})) ::
          term()
  def call(agent_or_catalog, boundary, context, func) do
    catalog = catalog_ref(agent_or_catalog)
    pre_event = :"pre_#{boundary}"
    post_event = :"post_#{boundary}"

    Telemetry.span([boundary], context, fn ->
      case fire(catalog, pre_event, context) do
        :ok ->
          {result, post_context} = func.()
          notify(catalog, post_event, post_context)
          {result, %{}, Map.put(context, :status, :ok)}

        {:deny, reason} ->
          {{:deny, reason}, %{}, Map.put(context, :status, :denied)}

        {:pending, state} ->
          {{:pending, state}, %{}, Map.put(context, :status, :suspended)}
      end
    end)
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
      func.() |> elem(0)
  end

  @doc """
  Fires a single hook event, fire-and-forget.
  """
  @spec cast(GenServer.server() | SkillKit.Agent.t(), Hook.event(), map()) :: :ok
  def cast(agent_or_catalog, event, context) do
    catalog = catalog_ref(agent_or_catalog)
    notify(catalog, event, context)
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] -> :ok
  end

  # -- Private: catalog resolution ------------------------------------------

  defp catalog_ref(%SkillKit.Agent{} = agent) do
    {:via, Registry, {agent.registry, {agent.name, :catalog}}}
  end

  defp catalog_ref(server), do: server

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
    |> Enum.each(fn hook ->
      try do
        invoke_handler(hook.handler, context)
      rescue
        e ->
          Logger.warning("Post-event hook handler failed: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  defp reduce_until_denied([], _context), do: :ok

  defp reduce_until_denied([hook | rest], context) do
    case invoke_handler(hook.handler, context) do
      :ok ->
        reduce_until_denied(rest, context)

      {:deny, _reason} = deny ->
        deny

      {:pending, _state} = pending ->
        pending

      other ->
        Logger.warning("Hook handler returned unexpected value: #{inspect(other)}")
        reduce_until_denied(rest, context)
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
