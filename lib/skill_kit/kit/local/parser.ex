defmodule SkillKit.Kit.Local.Parser do
  @moduledoc """
  Internal parser for the Local provider.

  Parses `SKILL.md` files into `%SkillKit.Skill{}` structs. This module is
  internal to the Local provider — callers outside the provider should not
  depend on it directly.

  A `SKILL.md` file combines a YAML frontmatter section with a markdown
  prompt template body. The frontmatter must contain exactly the required
  fields; the body below the second `---` delimiter becomes the prompt
  template stored in `%Skill{body: ...}`.

  ## File Format

  ```
  ---
  name: "namespace:skill_name"
  description: "Human-readable description"
  required_scope:
    - "namespace:permission"
  ---
  Your prompt template goes here.

  Use {{arg_name}} to reference arguments passed at execution time.
  ```

  ## Required Fields

  | Field | Type | Notes |
  |-------|------|-------|
  | `name` | `String.t()` | Must follow `"namespace:skill_name"` format |
  | `description` | `String.t()` | Non-empty description |

  ## Optional Fields

  | Field | Type | Default | Notes |
  |-------|------|---------|-------|
  | `required_scope` | `[String.t()] \| String.t()` | `[]` | Single string coerced to list |

  ## Security Note

  YAML is always parsed with `atoms: false` — skill files must not be able to
  exhaust the BEAM atom table. Map keys from YAML are always strings, never atoms.

  ## Example

      iex> SkillKit.Kit.Local.Parser.load_file("/path/to/skills/summarize/SKILL.md")
      {:ok, %SkillKit.Skill{
        name: "files:summarize",
        namespace: "files",
        description: "Summarize a file's contents",
        required_scope: ["files:read"],
        body: "Please summarize: {{content}}",
        location: "/path/to/skills/summarize/SKILL.md"
      }}
  """

  require Logger

  alias SkillKit.Hook
  alias SkillKit.Skill

  # Built in a function (not a module attribute): a compiled regex holds a
  # #Reference under OTP 28, which can't be escaped into an attribute.
  defp name_segment_regex, do: ~r/^[a-z][a-z0-9_-]*$/

  @doc """
  Loads a `SKILL.md` file from `path` and returns a parsed skill struct.

  Returns `{:ok, %SkillKit.Skill{}}` on success.

  Returns `{:error, reason}` on failure:
  - `{:error, :enoent}` — file does not exist
  - `{:error, :invalid_frontmatter}` — file missing `---` delimiters
  - `{:error, %YamlElixir.ParsingError{}}` — YAML could not be parsed
  - `{:error, {:missing_field, field}}` — required field absent or empty
  - `{:error, {:invalid_field, field}}` — field present but wrong type
  - `{:error, :invalid_name_format}` — name doesn't match `"namespace:skill_name"` format
  """
  @spec load_file(Path.t()) :: {:ok, Skill.t()} | {:error, term()}
  def load_file(path) do
    with {:ok, content} <- SkillKit.Storage.read(path),
         {:ok, yaml_map, body} <- SkillKit.Frontmatter.parse(content) do
      build_skill(yaml_map, body, path)
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Skill construction
  # ---------------------------------------------------------------------------

  # Validates required fields and builds a %Skill{} struct.
  #
  # Field access always uses string keys — yaml_elixir with atoms: false
  # returns string-keyed maps.
  @spec build_skill(map(), String.t(), Path.t()) :: {:ok, Skill.t()} | {:error, term()}
  defp build_skill(yaml_map, body, source_path) do
    with {:ok, name} <- fetch_required_field(yaml_map, "name"),
         {:ok, description} <- fetch_required_field(yaml_map, "description"),
         {:ok, required_scope} <- fetch_scope(yaml_map),
         {:ok, namespace} <- validate_name_format(name),
         {:ok, hooks} <- parse_hooks(yaml_map) do
      {:ok,
       %Skill{
         name: name,
         namespace: namespace,
         description: description,
         required_scope: required_scope,
         body: body,
         location: source_path,
         hooks: hooks,
         metadata: Map.get(yaml_map, "metadata", %{})
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Hook parsing
  # ---------------------------------------------------------------------------

  # Converts the hook YAML format into a list of %Hook{} structs.
  #
  # Event names map to boundary-derived atoms:
  #   - "PreToolUse"  → :pre_tool_use
  #   - "PostToolUse" → :post_tool_use
  #   - etc.
  #
  # Unknown event names are silently ignored.
  # If no "hooks" key is present, returns {:ok, []}.
  @spec parse_hooks(map()) :: {:ok, [Hook.t()]}

  @event_map %{
    "PreToolUse" => :pre_tool_use,
    "PostToolUse" => :post_tool_use,
    "PreSubagent" => :pre_subagent,
    "PostSubagent" => :post_subagent,
    "PreSkillActivation" => :pre_skill_activation,
    "PostSkillActivation" => :post_skill_activation,
    "PreConversationSave" => :pre_conversation_save,
    "PostConversationSave" => :post_conversation_save,
    "PreConversationLoad" => :pre_conversation_load,
    "PostConversationLoad" => :post_conversation_load,
    "PreLlmRequest" => :pre_llm_request,
    "PostLlmRequest" => :post_llm_request,
    "PreTurn" => :pre_turn,
    "PostTurn" => :post_turn,
    "PreAgent" => :pre_agent,
    "PostAgent" => :post_agent
  }

  defp parse_hooks(yaml_map) do
    hook_handlers = Application.get_env(:skill_kit, :hook_handlers, %{})

    hooks =
      yaml_map
      |> Map.get("hooks", %{})
      |> Enum.flat_map(&parse_hook_event(&1, hook_handlers))

    {:ok, hooks}
  end

  defp parse_hook_event({event_name, entries}, hook_handlers) do
    case Map.fetch(@event_map, event_name) do
      {:ok, event} -> Enum.map(entries, &build_hook(event, &1, hook_handlers))
      :error -> []
    end
  end

  defp build_hook(event, entry, hook_handlers) do
    %Hook{
      event: event,
      matcher: compile_matcher(Map.get(entry, "matcher")),
      handler: build_hook_handler(Map.get(entry, "hooks", []), hook_handlers)
    }
  end

  defp compile_matcher(nil), do: nil
  defp compile_matcher(pattern), do: Regex.compile!(pattern)

  @spec build_hook_handler(list(), map()) :: Hook.handler()
  defp build_hook_handler([config], hook_handlers) do
    resolve_handler(config, hook_handlers)
  end

  defp build_hook_handler([config | _rest], hook_handlers) do
    Logger.warning("Multiple handlers per matcher entry not supported; using first")
    resolve_handler(config, hook_handlers)
  end

  defp build_hook_handler(_other, _hook_handlers) do
    fn _context -> :ok end
  end

  defp resolve_handler(%{"type" => type} = config, hook_handlers) do
    case Map.fetch(hook_handlers, type) do
      {:ok, handler_mod} ->
        handler_config = Map.drop(config, ["type"])
        {handler_mod, handler_config}

      :error ->
        Logger.warning("Unknown hook handler type: #{type}")
        fn _context -> :ok end
    end
  end

  # Fetches a required string field from the YAML map.
  # Returns {:error, {:missing_field, key}} if absent, nil, or empty string.
  @spec fetch_required_field(map(), String.t()) ::
          {:ok, String.t()} | {:error, {:missing_field, String.t()}}
  defp fetch_required_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, _other} ->
        # Present but nil, empty string, or wrong type
        {:error, {:missing_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  # Fetches the optional required_scope field.
  # Defaults to []. Coerces single string to [string]. Rejects other types.
  @spec fetch_scope(map()) ::
          {:ok, [String.t()]} | {:error, {:invalid_field, String.t()}}
  defp fetch_scope(map) do
    case Map.get(map, "required_scope", []) do
      list when is_list(list) ->
        {:ok, list}

      string when is_binary(string) ->
        {:ok, [string]}

      _other ->
        {:error, {:invalid_field, "required_scope"}}
    end
  end

  # Validates that name matches "namespace:skill_name" format.
  # Returns {:ok, namespace} on success or {:error, :invalid_name_format} on failure.
  #
  # Validation rules:
  # - Exactly one colon separating namespace and skill name, or a bare name
  # - Both segments must be non-empty
  # - Both segments must match ~r/^[a-z][a-z0-9_-]*$/ (lowercase, letter start)
  @spec validate_name_format(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_name_format}
  defp validate_name_format(name) do
    case String.split(name, ":", parts: 2) do
      [namespace, skill_name]
      when namespace != "" and skill_name != "" ->
        if Regex.match?(name_segment_regex(), namespace) and
             Regex.match?(name_segment_regex(), skill_name) do
          {:ok, namespace}
        else
          {:error, :invalid_name_format}
        end

      [bare_name] when bare_name != "" ->
        if Regex.match?(name_segment_regex(), bare_name) do
          {:ok, bare_name}
        else
          {:error, :invalid_name_format}
        end

      _ ->
        {:error, :invalid_name_format}
    end
  end
end
