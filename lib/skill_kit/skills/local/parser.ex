defmodule SkillKit.Skills.Local.Parser do
  @moduledoc """
  Internal parser for the Local provider.

  Parses `.skill.md` files into `%SkillKit.Skill{}` structs. This module is
  internal to the Local provider — callers outside the provider should not
  depend on it directly.

  A `.skill.md` file combines a YAML frontmatter section with a markdown
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

      iex> SkillKit.Skills.Local.Parser.load_file("/path/to/summarize.skill.md")
      {:ok, %SkillKit.Skill{
        type: :prompt,
        name: "files:summarize",
        namespace: "files",
        description: "Summarize a file's contents",
        required_scope: ["files:read"],
        body: "Please summarize: {{content}}",
        source: "/path/to/summarize.skill.md"
      }}
  """

  alias SkillKit.Hook
  alias SkillKit.Skill

  # Namespace segment validation — same regex as SkillKit.Registry
  @name_segment_regex ~r/^[a-z][a-z0-9_-]*$/

  @doc """
  Loads a `.skill.md` file from `path` and returns a parsed skill struct.

  Returns `{:ok, %SkillKit.Skill{type: :prompt, ...}}` on success.

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
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, body} <- split_frontmatter(content),
         {:ok, yaml_map} <- parse_yaml(frontmatter) do
      build_skill(yaml_map, body, path)
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Frontmatter splitting
  # ---------------------------------------------------------------------------

  # Splits content formatted as "---\n{yaml}\n---\n{body}" into its parts.
  #
  # Handles the standard frontmatter convention where the file starts with "---"
  # as the opening delimiter. The closing delimiter must be on its own line
  # surrounded by newlines to avoid false matches on YAML content that
  # legitimately contains "---".
  @spec split_frontmatter(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :invalid_frontmatter}
  defp split_frontmatter(content) do
    # Strip the leading "---\n" delimiter if present (standard frontmatter convention)
    rest =
      if String.starts_with?(content, "---\n") do
        String.slice(content, 4, byte_size(content))
      else
        content
      end

    # Split on "\n---\n" to find the closing frontmatter delimiter.
    # Using parts: 2 so we get exactly [frontmatter, body] even if body contains "---".
    case String.split(rest, ~r/\n---(\n|$)/, parts: 2) do
      [frontmatter, body] ->
        {:ok, frontmatter, String.trim(body)}

      _ ->
        {:error, :invalid_frontmatter}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: YAML parsing
  # ---------------------------------------------------------------------------

  # Parses a YAML string using yaml_elixir with atoms: false.
  #
  # atoms: false is the yaml_elixir default, but we make it explicit here as a
  # security signal — skill files must never be allowed to grow the BEAM atom table.
  @spec parse_yaml(String.t()) :: {:ok, map()} | {:error, term()}
  defp parse_yaml(yaml_str) do
    YamlElixir.read_from_string(yaml_str, atoms: false)
  end

  # ---------------------------------------------------------------------------
  # Private: Skill construction
  # ---------------------------------------------------------------------------

  # Validates required fields and builds a %Skill{type: :prompt} struct.
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

  # Converts the Claude Code hook YAML format into a list of %Hook{} structs.
  #
  # Supported event names:
  #   - "PreToolUse"  → phase: :pre
  #   - "PostToolUse" → phase: :post
  #
  # Other event names are silently ignored.
  # If no "hooks" key is present, returns {:ok, []}.
  @spec parse_hooks(map()) :: {:ok, [Hook.t()]}
  @phase_map %{"PreToolUse" => :pre, "PostToolUse" => :post}

  defp parse_hooks(yaml_map) do
    hooks =
      yaml_map
      |> Map.get("hooks", %{})
      |> Enum.flat_map(&parse_hook_event/1)

    {:ok, hooks}
  end

  defp parse_hook_event({event_name, entries}) do
    case Map.fetch(@phase_map, event_name) do
      {:ok, phase} -> Enum.map(entries, &build_hook(phase, &1))
      :error -> []
    end
  end

  defp build_hook(phase, entry) do
    %Hook{
      phase: phase,
      matcher: Regex.compile!(Map.get(entry, "matcher", ".*")),
      handler: build_hook_handler(Map.get(entry, "hooks", []))
    }
  end

  # Builds a handler function from a list of hook handler definitions.
  #
  # For "type: command", returns a function that shells out to the command.
  # Unknown types return a no-op handler that returns :allow.
  # When multiple handler definitions are given, the first one wins.
  @spec build_hook_handler(list()) :: Hook.handler()
  defp build_hook_handler([%{"type" => "command", "command" => cmd} | _rest]) do
    fn context -> run_command_hook(context, cmd) end
  end

  defp build_hook_handler(_other) do
    fn context -> noop_hook(context) end
  end

  defp run_command_hook(%{result: _}, cmd) do
    # Post-hook: run command, always succeed (post hooks are observational)
    System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
    {:ok, :completed}
  end

  defp run_command_hook(_context, cmd) do
    # Pre-hook: command exit code determines allow/deny
    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_output, 0} -> :allow
      {output, _code} -> {:deny, output}
    end
  end

  defp noop_hook(%{result: _}), do: {:ok, :completed}
  defp noop_hook(_context), do: :allow

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
  # Validation rules (same as SkillKit.Registry):
  # - Exactly one colon separating namespace and skill name
  # - Both segments must be non-empty
  # - Both segments must match ~r/^[a-z][a-z0-9_-]*$/ (lowercase, letter start)
  @spec validate_name_format(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_name_format}
  defp validate_name_format(name) do
    case String.split(name, ":", parts: 2) do
      [namespace, skill_name]
      when namespace != "" and skill_name != "" ->
        if Regex.match?(@name_segment_regex, namespace) and
             Regex.match?(@name_segment_regex, skill_name) do
          {:ok, namespace}
        else
          {:error, :invalid_name_format}
        end

      [bare_name] when bare_name != "" ->
        if Regex.match?(@name_segment_regex, bare_name) do
          {:ok, bare_name}
        else
          {:error, :invalid_name_format}
        end

      _ ->
        {:error, :invalid_name_format}
    end
  end
end
