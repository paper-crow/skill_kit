defmodule SkillKit.AuthorizationTest do
  use ExUnit.Case, async: true

  alias SkillKit.Authorization
  alias SkillKit.Skill

  # ---------------------------------------------------------------------------
  # Inline test provider modules
  # These implement @behaviour SkillKit.AuthorizationProvider and are used
  # exclusively within this test file to avoid namespace pollution.
  # ---------------------------------------------------------------------------

  defmodule GrantAll do
    @behaviour SkillKit.AuthorizationProvider
    @impl SkillKit.AuthorizationProvider
    def resolve_scopes(_ctx), do: {:ok, ["admin:read", "admin:write", "tools:*"]}
  end

  defmodule GrantNone do
    @behaviour SkillKit.AuthorizationProvider
    @impl SkillKit.AuthorizationProvider
    def resolve_scopes(_ctx), do: {:ok, []}
  end

  defmodule ErrorProvider do
    @behaviour SkillKit.AuthorizationProvider
    @impl SkillKit.AuthorizationProvider
    def resolve_scopes(_ctx), do: {:error, :token_expired}
  end

  defmodule ContextEchoProvider do
    @behaviour SkillKit.AuthorizationProvider
    @impl SkillKit.AuthorizationProvider
    def resolve_scopes(%{scopes: scopes}), do: {:ok, scopes}
    def resolve_scopes(_ctx), do: {:error, :missing_scopes}
  end

  defmodule CrashProvider do
    @behaviour SkillKit.AuthorizationProvider
    @impl SkillKit.AuthorizationProvider
    def resolve_scopes(_ctx), do: raise("provider crashed")
  end

  # ---------------------------------------------------------------------------
  # Helper
  # ---------------------------------------------------------------------------

  defp skill(required_scope) do
    %Skill{name: "test:skill", namespace: "test", required_scope: required_scope}
  end

  # ---------------------------------------------------------------------------
  # authorize/2 — direct mode
  # ---------------------------------------------------------------------------

  describe "authorize/2 — direct mode" do
    test "exact matching scope returns {:ok, skill}" do
      s = skill(["admin:read"])
      assert {:ok, ^s} = Authorization.authorize(s, ["admin:read"])
    end

    test "wildcard granted scope covers required exact scope" do
      s = skill(["admin:read"])
      assert {:ok, ^s} = Authorization.authorize(s, ["admin:*"])
    end

    test "insufficient scopes return {:error, :unauthorized}" do
      s = skill(["admin:read"])
      assert {:error, :unauthorized} = Authorization.authorize(s, ["tools:read"])
    end

    test "empty required_scope returns {:ok, skill} regardless of granted scopes" do
      s = skill([])
      assert {:ok, ^s} = Authorization.authorize(s, [])
      assert {:ok, ^s} = Authorization.authorize(s, ["admin:read"])
    end

    test "multiple required scopes — all covered returns {:ok, skill}" do
      s = skill(["admin:read", "tools:execute"])
      assert {:ok, ^s} = Authorization.authorize(s, ["admin:read", "tools:execute"])
    end

    test "multiple required scopes — wildcard covers all" do
      s = skill(["admin:read", "admin:write"])
      assert {:ok, ^s} = Authorization.authorize(s, ["admin:*"])
    end

    test "multiple required scopes — one missing returns {:error, :unauthorized}" do
      s = skill(["admin:read", "tools:execute"])
      assert {:error, :unauthorized} = Authorization.authorize(s, ["admin:read"])
    end

    test "empty granted list with non-empty required returns {:error, :unauthorized}" do
      s = skill(["admin:read"])
      assert {:error, :unauthorized} = Authorization.authorize(s, [])
    end
  end

  # ---------------------------------------------------------------------------
  # authorized?/2 — boolean convenience
  # ---------------------------------------------------------------------------

  describe "authorized?/2 — boolean convenience" do
    test "returns true when authorize/2 would return {:ok, _}" do
      s = skill(["admin:read"])
      assert Authorization.authorized?(s, ["admin:read"]) == true
    end

    test "returns false when authorize/2 would return {:error, _}" do
      s = skill(["admin:read"])
      assert Authorization.authorized?(s, ["tools:read"]) == false
    end

    test "returns true for empty required_scope regardless of granted" do
      s = skill([])
      assert Authorization.authorized?(s, []) == true
    end

    test "returns true for wildcard grant covering required" do
      s = skill(["admin:read"])
      assert Authorization.authorized?(s, ["admin:*"]) == true
    end

    test "returns false when one of multiple required scopes is missing" do
      s = skill(["admin:read", "tools:execute"])
      assert Authorization.authorized?(s, ["admin:read"]) == false
    end
  end

  # ---------------------------------------------------------------------------
  # authorize/3 — provider mode
  # ---------------------------------------------------------------------------

  describe "authorize/3 — provider mode" do
    test "GrantAll provider with matching required scope returns {:ok, skill}" do
      s = skill(["admin:read"])
      assert {:ok, ^s} = Authorization.authorize(s, GrantAll, %{})
    end

    test "GrantAll provider with wildcard-covered required scope returns {:ok, skill}" do
      s = skill(["tools:execute"])
      assert {:ok, ^s} = Authorization.authorize(s, GrantAll, %{})
    end

    test "GrantNone provider returns {:error, :unauthorized}" do
      s = skill(["admin:read"])
      assert {:error, :unauthorized} = Authorization.authorize(s, GrantNone, %{})
    end

    test "ErrorProvider returns {:error, :token_expired} (pass-through)" do
      s = skill(["admin:read"])
      assert {:error, :token_expired} = Authorization.authorize(s, ErrorProvider, %{})
    end

    test "empty required_scope returns {:ok, skill} WITHOUT calling provider" do
      # CrashProvider would raise if called — proving provider is skipped
      s = skill([])
      assert {:ok, ^s} = Authorization.authorize(s, CrashProvider, %{})
    end

    test "authorize/3 passes context map to provider.resolve_scopes/1" do
      s = skill(["admin:read"])
      ctx = %{scopes: ["admin:read", "tools:*"]}
      assert {:ok, ^s} = Authorization.authorize(s, ContextEchoProvider, ctx)
    end

    test "ContextEchoProvider with insufficient scopes in context returns {:error, :unauthorized}" do
      s = skill(["admin:read"])
      ctx = %{scopes: ["tools:read"]}
      assert {:error, :unauthorized} = Authorization.authorize(s, ContextEchoProvider, ctx)
    end

    test "ContextEchoProvider with missing_scopes key returns {:error, :missing_scopes}" do
      s = skill(["admin:read"])
      assert {:error, :missing_scopes} = Authorization.authorize(s, ContextEchoProvider, %{})
    end

    test "CrashProvider raises RuntimeError (let it crash — no rescue)" do
      s = skill(["admin:read"])

      assert_raise RuntimeError, "provider crashed", fn ->
        Authorization.authorize(s, CrashProvider, %{})
      end
    end

    test "multiple required scopes all covered by provider grants returns {:ok, skill}" do
      s = skill(["admin:read", "admin:write"])
      assert {:ok, ^s} = Authorization.authorize(s, GrantAll, %{})
    end

    test "multiple required scopes one not covered returns {:error, :unauthorized}" do
      s = skill(["admin:read", "tools:execute"])

      # GrantAll grants ["admin:read", "admin:write", "tools:*"] — tools:execute IS covered by tools:*
      assert {:ok, ^s} = Authorization.authorize(s, GrantAll, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # error signal distinction — AUTH-03
  # ---------------------------------------------------------------------------

  describe "error signal distinction" do
    test "authorize/2 only returns :unauthorized, never :not_found" do
      s = skill(["admin:read"])
      assert {:error, :unauthorized} = Authorization.authorize(s, ["tools:read"])
    end

    test "authorize/3 with valid provider only returns :unauthorized or provider reason — never :not_found" do
      s = skill(["admin:read"])
      assert {:error, :unauthorized} = Authorization.authorize(s, GrantNone, %{})
    end

    test "provider error passes through as-is — not normalized to :unauthorized" do
      s = skill(["admin:read"])
      assert {:error, :token_expired} = Authorization.authorize(s, ErrorProvider, %{})
    end
  end
end
