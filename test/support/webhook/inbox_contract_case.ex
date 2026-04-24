defmodule SkillKit.Webhook.Inbox.ContractCase do
  @moduledoc """
  Shared contract tests for `SkillKit.Webhook.Inbox` implementations.

  An implementation's test module `use`s this case template with the impl
  module as an option; the contract suite exercises every behaviour callback
  against the live impl. Impl-specific concerns (retention policy specifics,
  dispatch callback shape, internal representation) belong in the impl's own
  test file alongside the `use` directive.

  ## Usage

      defmodule SkillKit.Webhook.Inbox.MemoryTest do
        use SkillKit.Webhook.Inbox.ContractCase,
          impl: SkillKit.Webhook.Inbox.Memory

        setup do
          name = :"\#{__MODULE__}_\#{System.unique_integer([:positive])}"
          {:ok, _pid} = SkillKit.Webhook.Inbox.Memory.start_link(
            name: name,
            dispatch: fn _a, _t, _o -> :ok end
          )
          {:ok, inbox: name}
        end

        # ... impl-specific tests
      end

  ## Contract guaranteed

  The suite calls the impl module's behaviour callbacks (`put`, `read`,
  `summary`, `list`, `delete`) and asserts:

    * `put` → delivery retrievable via `summary`, `read`, and `list`
    * `read` selector traversal (scalars, objects, arrays, projections, headers)
    * `read` array `offset`/`limit`
    * `read` byte range (`offset_bytes` / `limit_bytes`)
    * `read` line range (`line_start` / `line_end`)
    * `read` `limit_bytes` cap sets `truncated: true` with `total`
    * `read` returns `{:error, :not_found}` / `{:error, :invalid_selector}`
    * `summary` returns the shape tree with headers + body structural keys
    * `list` returns newest-first, scoped to agent
    * `delete` evicts the delivery

  Impls must support these semantics to pass. Impl-specific features
  (retention caps, telemetry, etc.) are tested outside this case.
  """

  use ExUnit.CaseTemplate

  using opts do
    impl = Keyword.fetch!(opts, :impl)
    parts = __all_contracts__()

    quote do
      @impl_module unquote(impl)

      import SkillKit.Webhook.Inbox.ContractCase,
        only: [build_entry: 0, build_entry: 1, agent_ref: 1]

      unquote_splicing(parts)
    end
  end

  @doc false
  def __all_contracts__ do
    [
      __put_contract__(),
      __selector_contract__(),
      __array_contract__(),
      __byte_line_contract__(),
      __summary_contract__(),
      __list_contract__(),
      __delete_contract__()
    ]
  end

  @doc false
  def __put_contract__ do
    quote do
      describe "put/2 (contract)" do
        test "persists the delivery so it can be read back", %{inbox: inbox} do
          e = build_entry()
          assert :ok = @impl_module.put(inbox, e)

          assert {:ok, summary} =
                   @impl_module.summary(inbox, e.delivery.agent_name, e.delivery.id)

          assert summary.id == e.delivery.id
        end
      end
    end
  end

  @doc false
  def __selector_contract__ do
    quote do
      describe "read/4 selector traversal (contract)" do
        setup %{inbox: inbox} do
          body =
            Jason.encode!(%{
              "ref" => "refs/heads/main",
              "commits" => [
                %{"id" => "c1", "message" => "first"},
                %{"id" => "c2", "message" => "second"}
              ]
            })

          e = build_entry(%{delivery: %{id: "dlv_sel", body: body}})
          :ok = @impl_module.put(inbox, e)
          {:ok, id: "dlv_sel"}
        end

        test "scalar", %{inbox: inbox, id: id} do
          assert {:ok, %{value: "refs/heads/main", truncated: false}} =
                   @impl_module.read(inbox, "agent-1", id, selector: "body.ref")
        end

        test "object", %{inbox: inbox, id: id} do
          assert {:ok, %{value: %{"id" => "c1", "message" => "first"}}} =
                   @impl_module.read(inbox, "agent-1", id, selector: "body.commits[0]")
        end

        test "array projection", %{inbox: inbox, id: id} do
          assert {:ok, %{value: ["first", "second"]}} =
                   @impl_module.read(inbox, "agent-1", id, selector: "body.commits[].message")
        end

        test "header lookup", %{inbox: inbox, id: id} do
          assert {:ok, %{value: "push"}} =
                   @impl_module.read(inbox, "agent-1", id, selector: "headers.x-github-event")
        end

        test "invalid selector", %{inbox: inbox, id: id} do
          assert {:error, :invalid_selector} =
                   @impl_module.read(inbox, "agent-1", id, selector: "body.nope.deep")
        end

        test "unknown id", %{inbox: inbox} do
          assert {:error, :not_found} =
                   @impl_module.read(inbox, "agent-1", "ghost", selector: "body")
        end
      end
    end
  end

  @doc false
  def __array_contract__ do
    quote do
      describe "read/4 array offset/limit (contract)" do
        setup %{inbox: inbox} do
          commits = Enum.map(1..5, fn i -> %{"id" => "c#{i}", "message" => "msg #{i}"} end)
          body = Jason.encode!(%{"commits" => commits})

          :ok = @impl_module.put(inbox, build_entry(%{delivery: %{id: "dlv_arr", body: body}}))
          {:ok, id: "dlv_arr"}
        end

        test "offset + limit slices", %{inbox: inbox, id: id} do
          assert {:ok, %{value: ["msg 2", "msg 3"], total: 5}} =
                   @impl_module.read(inbox, "agent-1", id,
                     selector: "body.commits[].message",
                     offset: 1,
                     limit: 2
                   )
        end

        test "offset beyond length", %{inbox: inbox, id: id} do
          assert {:ok, %{value: [], total: 5}} =
                   @impl_module.read(inbox, "agent-1", id,
                     selector: "body.commits[].id",
                     offset: 99
                   )
        end
      end
    end
  end

  @doc false
  def __byte_line_contract__ do
    quote do
      describe "read/4 byte + line ranges (contract)" do
        setup %{inbox: inbox} do
          body = Enum.map_join(1..20, "\n", fn i -> "line #{i}" end)

          :ok = @impl_module.put(inbox, build_entry(%{delivery: %{id: "dlv_text", body: body}}))
          {:ok, id: "dlv_text"}
        end

        test "line range", %{inbox: inbox, id: id} do
          assert {:ok, %{value: "line 3\nline 4\nline 5"}} =
                   @impl_module.read(inbox, "agent-1", id,
                     selector: "body",
                     as: :text,
                     line_start: 2,
                     line_end: 5
                   )
        end

        test "byte range", %{inbox: inbox, id: id} do
          assert {:ok, %{value: "line 1", bytes: 6}} =
                   @impl_module.read(inbox, "agent-1", id,
                     selector: "body",
                     as: :text,
                     offset_bytes: 0,
                     limit_bytes: 6
                   )
        end

        test "limit_bytes caps with truncated + total", %{inbox: inbox, id: id} do
          assert {:ok, %{value: value, truncated: true, total: total}} =
                   @impl_module.read(inbox, "agent-1", id,
                     selector: "body",
                     as: :text,
                     limit_bytes: 10
                   )

          assert byte_size(value) == 10
          assert total > 10
        end
      end
    end
  end

  @doc false
  def __summary_contract__ do
    quote do
      describe "summary/3 (contract)" do
        test "shape tree with headers, method, body structural keys", %{inbox: inbox} do
          body =
            Jason.encode!(%{
              "ref" => "main",
              "commits" => [%{"id" => "c1"}, %{"id" => "c2"}]
            })

          e = build_entry(%{delivery: %{id: "dlv_sum", body: body}})
          :ok = @impl_module.put(inbox, e)

          assert {:ok, summary} = @impl_module.summary(inbox, "agent-1", "dlv_sum")
          assert summary.id == "dlv_sum"
          assert summary.method == "POST"
          assert summary.body_bytes > 0
          assert summary.headers == e.delivery.headers
          assert %{"type" => "object", "keys" => body_keys} = summary.body
          assert Map.has_key?(body_keys, "ref")
          assert body_keys["commits"]["type"] == "array"
          assert body_keys["commits"]["length"] == 2
        end

        test "unknown id returns :not_found", %{inbox: inbox} do
          assert {:error, :not_found} = @impl_module.summary(inbox, "agent-1", "ghost")
        end
      end
    end
  end

  @doc false
  def __list_contract__ do
    quote do
      describe "list/3 (contract)" do
        test "newest first", %{inbox: inbox} do
          :ok =
            @impl_module.put(
              inbox,
              build_entry(%{delivery: %{id: "a", received_at: ~U[2026-01-01 00:00:00Z]}})
            )

          :ok =
            @impl_module.put(
              inbox,
              build_entry(%{delivery: %{id: "b", received_at: ~U[2026-01-02 00:00:00Z]}})
            )

          :ok =
            @impl_module.put(
              inbox,
              build_entry(%{delivery: %{id: "c", received_at: ~U[2026-01-03 00:00:00Z]}})
            )

          assert {:ok, summaries} = @impl_module.list(inbox, "agent-1", [])
          assert Enum.map(summaries, & &1.id) == ["c", "b", "a"]
        end

        test "scoped to the agent", %{inbox: inbox} do
          :ok =
            @impl_module.put(
              inbox,
              build_entry(%{delivery: %{id: "mine", agent_name: "agent-1"}})
            )

          :ok =
            @impl_module.put(inbox, %{
              agent: agent_ref("other"),
              prompt: "p",
              delivery: %{
                id: "not-mine",
                webhook_id: "w",
                agent_name: "other",
                received_at: DateTime.utc_now(),
                method: "POST",
                headers: %{},
                query: %{},
                body: "{}"
              }
            })

          assert {:ok, summaries} = @impl_module.list(inbox, "agent-1", [])
          assert Enum.map(summaries, & &1.id) == ["mine"]
        end
      end
    end
  end

  @doc false
  def __delete_contract__ do
    quote do
      describe "delete/3 (contract)" do
        test "evicts a delivery", %{inbox: inbox} do
          :ok = @impl_module.put(inbox, build_entry(%{delivery: %{id: "ephemeral"}}))
          assert {:ok, _} = @impl_module.summary(inbox, "agent-1", "ephemeral")
          assert :ok = @impl_module.delete(inbox, "agent-1", "ephemeral")
          assert {:error, :not_found} = @impl_module.summary(inbox, "agent-1", "ephemeral")
        end
      end
    end
  end

  # -- shared helpers used by the injected tests --------------------------

  @doc false
  def build_entry(overrides \\ %{}) do
    delivery =
      Map.merge(
        %{
          id: "dlv_#{System.unique_integer([:positive])}",
          webhook_id: "wh_abc",
          agent_name: "agent-1",
          received_at: DateTime.utc_now(),
          method: "POST",
          headers: %{"x-github-event" => "push", "content-type" => "application/json"},
          query: %{"installation" => "42"},
          body: ~s({"ref":"refs/heads/main","commits":[{"id":"c1","message":"fix: bug"}]})
        },
        Map.get(overrides, :delivery, %{})
      )

    %{
      agent: agent_ref(delivery.agent_name),
      prompt: Map.get(overrides, :prompt, "Process this webhook."),
      delivery: delivery
    }
  end

  @doc false
  def agent_ref(name) do
    %SkillKit.AgentRef{name: name, registry: :test_registry, supervisor_pid: nil}
  end
end
