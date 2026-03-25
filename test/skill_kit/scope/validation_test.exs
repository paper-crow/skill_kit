defmodule SkillKit.Scope.ValidationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SkillKit.Scope.Validation

  # ---------------------------------------------------------------------------
  # Private StreamData generators
  # ---------------------------------------------------------------------------

  # Generates a lowercase identifier matching ^[a-z][a-z0-9_-]*$
  defp scope_segment do
    tail_char =
      StreamData.one_of([
        StreamData.integer(?a..?z),
        StreamData.integer(?0..?9),
        StreamData.constant(?_),
        StreamData.constant(?-)
      ])

    gen all(
          first <- StreamData.integer(?a..?z),
          rest <- StreamData.list_of(tail_char, min_length: 0, max_length: 10)
        ) do
      List.to_string([first | rest])
    end
  end

  # Generates exact scopes like "namespace:action"
  defp exact_scope do
    gen all(
          ns <- scope_segment(),
          action <- scope_segment()
        ) do
      "#{ns}:#{action}"
    end
  end

  # ---------------------------------------------------------------------------
  # SCOPE-01: Format validation — valid?/1
  # ---------------------------------------------------------------------------

  describe "valid?/1" do
    test "returns true for exact scope" do
      assert Validation.valid?("admin:read") == true
    end

    test "returns true for wildcard scope" do
      assert Validation.valid?("admin:*") == true
    end

    test "returns false for empty string" do
      assert Validation.valid?("") == false
    end

    test "returns false for bare wildcard" do
      assert Validation.valid?("*") == false
    end

    test "returns false for double wildcard" do
      assert Validation.valid?("*:*") == false
    end

    test "returns false for missing colon (no action segment)" do
      assert Validation.valid?("admin") == false
    end

    test "returns false for empty namespace" do
      assert Validation.valid?(":read") == false
    end

    test "returns false for empty action" do
      assert Validation.valid?("admin:") == false
    end

    test "returns false for three-segment scope" do
      assert Validation.valid?("admin:tools:execute") == false
    end

    test "returns false for uppercase namespace" do
      assert Validation.valid?("Admin:read") == false
    end

    test "returns false for leading whitespace" do
      assert Validation.valid?(" admin:read") == false
    end

    test "returns false for trailing whitespace" do
      assert Validation.valid?("admin:read ") == false
    end

    test "returns false for embedded wildcard in action" do
      assert Validation.valid?("admin:read-*") == false
    end

    test "returns false for non-binary input" do
      assert Validation.valid?(nil) == false
      assert Validation.valid?(123) == false
      assert Validation.valid?(:admin) == false
    end
  end

  # ---------------------------------------------------------------------------
  # SCOPE-01: Format validation — validate/1
  # ---------------------------------------------------------------------------

  describe "validate/1" do
    test "returns {:ok, scope} for valid exact scope" do
      assert Validation.validate("admin:read") == {:ok, "admin:read"}
    end

    test "returns {:ok, scope} for valid wildcard scope" do
      assert Validation.validate("admin:*") == {:ok, "admin:*"}
    end

    test "returns {:error, {:invalid_scope_format, scope}} for empty string" do
      assert Validation.validate("") == {:error, {:invalid_scope_format, ""}}
    end

    test "returns {:error, {:invalid_scope_format, scope}} for bare wildcard" do
      assert Validation.validate("*") == {:error, {:invalid_scope_format, "*"}}
    end

    test "returns {:error, {:invalid_scope_format, scope}} for missing colon" do
      assert Validation.validate("admin") == {:error, {:invalid_scope_format, "admin"}}
    end

    test "returns {:error, :not_a_string} for integer" do
      assert Validation.validate(123) == {:error, :not_a_string}
    end

    test "returns {:error, :not_a_string} for nil" do
      assert Validation.validate(nil) == {:error, :not_a_string}
    end

    test "returns {:error, :not_a_string} for atom" do
      assert Validation.validate(:admin) == {:error, :not_a_string}
    end

    test "returns {:error, :leading_trailing_whitespace} for leading whitespace" do
      assert Validation.validate(" admin:read") == {:error, :leading_trailing_whitespace}
    end

    test "returns {:error, :leading_trailing_whitespace} for trailing whitespace" do
      assert Validation.validate("admin:read ") == {:error, :leading_trailing_whitespace}
    end
  end

  # ---------------------------------------------------------------------------
  # SCOPE-02: Exact match — covers?/2
  # ---------------------------------------------------------------------------

  describe "covers?/2" do
    test "returns true for exact match (same scope)" do
      assert Validation.covers?("admin:read", "admin:read") == true
    end

    test "returns false when action differs" do
      assert Validation.covers?("admin:read", "admin:write") == false
    end

    test "returns false when namespace differs" do
      assert Validation.covers?("admin:read", "other:read") == false
    end

    # SCOPE-03: Wildcard match
    test "wildcard covers any action in same namespace" do
      assert Validation.covers?("admin:*", "admin:read") == true
      assert Validation.covers?("admin:*", "admin:write") == true
      assert Validation.covers?("admin:*", "admin:delete-all") == true
    end

    test "wildcard does not cover a different namespace" do
      assert Validation.covers?("admin:*", "other:read") == false
    end

    # SCOPE-04: Segment boundary enforcement (critical security)
    test "wildcard does not cover a scope with a longer namespace prefix" do
      # CRITICAL: 'ski:*' must not cover 'skills:read' (substring prefix attack)
      assert Validation.covers?("ski:*", "skills:read") == false
    end

    test "wildcard does not cover a three-segment required scope" do
      assert Validation.covers?("admin:*", "admin:tools:execute") == false
    end

    test "wildcard does not cover an action that merely starts with the namespace" do
      assert Validation.covers?("admin:*", "administrator:read") == false
    end

    # Malformed input safety — must never raise
    test "returns false when granted is nil" do
      assert Validation.covers?(nil, "admin:read") == false
    end

    test "returns false when required is nil" do
      assert Validation.covers?("admin:read", nil) == false
    end

    test "returns false when granted is a bare wildcard" do
      assert Validation.covers?("*", "admin:read") == false
    end

    test "returns false when granted is empty string" do
      assert Validation.covers?("", "admin:read") == false
    end

    test "returns false for integer inputs" do
      assert Validation.covers?(42, "admin:read") == false
      assert Validation.covers?("admin:read", 42) == false
    end

    test "returns false for atom inputs" do
      assert Validation.covers?(:admin, "admin:read") == false
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-scope: any_covers?/2
  # ---------------------------------------------------------------------------

  describe "any_covers?/2" do
    test "returns true when an exact scope in the list matches" do
      assert Validation.any_covers?(["admin:read", "admin:write"], "admin:read") == true
    end

    test "returns true when a wildcard in the list covers the required scope" do
      assert Validation.any_covers?(["admin:*"], "admin:read") == true
    end

    test "returns false when no scope in the list covers the required scope" do
      assert Validation.any_covers?(["other:read"], "admin:read") == false
    end

    test "returns false for an empty granted list" do
      assert Validation.any_covers?([], "admin:read") == false
    end

    test "returns false when granted_list is nil (non-list)" do
      assert Validation.any_covers?(nil, "admin:read") == false
    end

    test "returns false when granted_list is not a list" do
      assert Validation.any_covers?("admin:*", "admin:read") == false
    end
  end

  # ---------------------------------------------------------------------------
  # SCOPE-05: StreamData property tests
  # ---------------------------------------------------------------------------

  property "covers?/2 is reflexive — every exact scope covers itself" do
    check all(scope <- exact_scope()) do
      assert Validation.covers?(scope, scope) == true
    end
  end

  property "covers?/2 wildcard grants same-namespace — ns:* covers ns:action" do
    check all(
            ns <- scope_segment(),
            action <- scope_segment()
          ) do
      wildcard = "#{ns}:*"
      required = "#{ns}:#{action}"
      assert Validation.covers?(wildcard, required) == true
    end
  end

  property "covers?/2 wildcard rejects different-namespace — ns1:* does not cover ns2:action when ns1 != ns2" do
    check all(
            ns1 <- scope_segment(),
            ns2 <- StreamData.filter(scope_segment(), fn s -> s != ns1 end),
            action <- scope_segment(),
            max_runs: 500
          ) do
      wildcard = "#{ns1}:*"
      required = "#{ns2}:#{action}"
      refute Validation.covers?(wildcard, required)
    end
  end

  property "covers?/2 malformed granted never matches a valid required scope" do
    check all(required <- exact_scope()) do
      # Bare wildcard
      refute Validation.covers?("*", required)
      # Three-segment scope as granted
      refute Validation.covers?("admin:tools:execute", required)
      # Empty string as granted
      refute Validation.covers?("", required)
    end
  end
end
