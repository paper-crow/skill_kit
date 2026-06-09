defmodule SkillKit.Scope.Validation do
  @moduledoc """
  Pure-function scope validation and wildcard matching for SkillKit.

  ## Scope Format

  Scopes are two-segment strings of the form `"namespace:action"`, where both
  segments must match `^[a-z][a-z0-9_-]*$` (lowercase ASCII, digits, hyphens,
  underscores). Examples: `"admin:read"`, `"skills:execute"`, `"tools:delete-all"`.

  A wildcard scope `"namespace:*"` is valid format and means "any action within
  the given namespace". The bare string `"*"` is NOT a valid scope.

  ## Matching Rules

  - **Exact match:** `"ns:action"` covers `"ns:action"` only.
  - **Wildcard match:** `"ns:*"` covers `"ns:action"` for any valid action.
  - **No cross-namespace bypass:** `"ns1:*"` does NOT cover `"ns2:action"` even
    if `ns1` is a substring of `ns2`.
  - **Segment boundary enforcement:** Three-segment strings (e.g. `"a:b:c"`) are
    never matched, even by a wildcard.

  ## Multi-Scope Semantics

  `any_covers?/2` checks whether ANY scope in a granted list covers the required
  scope (OR semantics). ALL-of semantics — where a caller must hold every
  required scope — are implemented in the `SkillKit.Authorization` module.

  ## Examples

      iex> SkillKit.Scope.Validation.valid?("admin:read")
      true

      iex> SkillKit.Scope.Validation.valid?("admin:*")
      true

      iex> SkillKit.Scope.Validation.valid?("*")
      false

      iex> SkillKit.Scope.Validation.covers?("admin:*", "admin:read")
      true

      iex> SkillKit.Scope.Validation.covers?("ski:*", "skills:read")
      false

      iex> SkillKit.Scope.Validation.any_covers?(["admin:*", "other:read"], "admin:write")
      true
  """

  # Same pattern as name_segment_regex/0 in Kit.Local.Parser.
  # Built in a function (not a module attribute): a compiled regex holds a
  # #Reference under OTP 28, which can't be escaped into an attribute.
  defp segment_regex, do: ~r/^[a-z][a-z0-9_-]*$/

  @typedoc ~S(A scope string, e.g. "admin:read" or "admin:*")
  @type scope :: String.t()

  @doc """
  Returns `true` when `scope` is a syntactically valid scope string.

  Accepts exact scopes (`"ns:action"`) and wildcard scopes (`"ns:*"`). Rejects
  non-binary values, whitespace-padded strings, bare `"*"`, three-segment
  strings, and strings with uppercase characters.
  """
  @spec valid?(term()) :: boolean()
  def valid?(scope) when is_binary(scope) do
    scope == String.trim(scope) and parse_scope(scope) != :invalid
  end

  def valid?(_), do: false

  @doc """
  Validates `scope` and returns a tagged tuple.

  Returns `{:ok, scope}` for valid scopes, or one of:
  - `{:error, :not_a_string}` — input is not a binary
  - `{:error, :leading_trailing_whitespace}` — binary has surrounding whitespace
  - `{:error, {:invalid_scope_format, scope}}` — binary but invalid format
  """
  @spec validate(term()) ::
          {:ok, scope()}
          | {:error,
             :not_a_string | :leading_trailing_whitespace | {:invalid_scope_format, term()}}
  def validate(scope) when is_binary(scope) do
    with :ok <- reject_whitespace(scope),
         :ok <- parse_and_validate(scope) do
      {:ok, scope}
    end
  end

  def validate(_), do: {:error, :not_a_string}

  @doc """
  Returns `true` when `granted` covers `required`.

  Supports exact match and wildcard match. Both arguments must be valid scope
  strings; any malformed or non-binary input returns `false` without raising.
  """
  @spec covers?(term(), term()) :: boolean()
  def covers?(granted, required) when is_binary(granted) and is_binary(required) do
    case {parse_scope(granted), parse_scope(required)} do
      {{:exact, ns, action}, {:exact, req_ns, req_action}} ->
        ns == req_ns and action == req_action

      {{:wildcard, ns}, {:exact, req_ns, _req_action}} ->
        ns == req_ns

      _ ->
        false
    end
  end

  def covers?(_, _), do: false

  @doc """
  Returns `true` when any scope in `granted_list` covers `required`.

  `granted_list` must be a list; any other value (including `nil`) returns
  `false`. Empty list returns `false`.
  """
  @spec any_covers?(term(), term()) :: boolean()
  def any_covers?(granted_list, required) when is_list(granted_list) do
    Enum.any?(granted_list, &covers?(&1, required))
  end

  def any_covers?(_, _), do: false

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Parses a scope string into {:exact, ns, action}, {:wildcard, ns}, or :invalid.
  # Using parts: 3 ensures three-segment strings produce a three-element list
  # that falls through to the catch-all :invalid clause.
  defp parse_scope(scope) do
    case String.split(scope, ":", parts: 3) do
      [ns, "*"] ->
        if Regex.match?(segment_regex(), ns), do: {:wildcard, ns}, else: :invalid

      [ns, action] ->
        if Regex.match?(segment_regex(), ns) and Regex.match?(segment_regex(), action) do
          {:exact, ns, action}
        else
          :invalid
        end

      _ ->
        :invalid
    end
  end

  defp reject_whitespace(scope) do
    if scope == String.trim(scope) do
      :ok
    else
      {:error, :leading_trailing_whitespace}
    end
  end

  defp parse_and_validate(scope) do
    case parse_scope(scope) do
      :invalid -> {:error, {:invalid_scope_format, scope}}
      _ -> :ok
    end
  end
end
