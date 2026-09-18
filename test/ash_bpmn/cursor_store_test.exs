# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.CursorStoreTest do
  @moduledoc """
  The seam ADR 0036 converges through, and the dual phase its migration note requires.
  """

  use AshBpmn.DataCase, async: false

  alias AshBpmn.Triggers.CursorStore

  defmodule Stub do
    @moduledoc false
    @behaviour AshBpmn.Triggers.CursorStore

    def set(position), do: Process.put({__MODULE__, :position}, position)
    def advanced, do: Process.get({__MODULE__, :advanced})
    def clear, do: Enum.each([:position, :advanced, :raise], &Process.delete({__MODULE__, &1}))
    def raise_on_read, do: Process.put({__MODULE__, :raise}, true)

    @impl true
    def read(_tenant, _ctx) do
      if Process.get({__MODULE__, :raise}), do: raise("converged store is broken")
      {:ok, Process.get({__MODULE__, :position})}
    end

    @impl true
    def advance(_tenant, position, _ctx) do
      Process.put({__MODULE__, :advanced}, position)
      :ok
    end
  end

  setup do
    Stub.clear()
    previous = Application.get_env(:ash_bpmn, :cursor_store)
    converged = Application.get_env(:ash_bpmn, :converged_cursor_store)

    on_exit(fn ->
      # Delete when it was unset. `put_env(key, nil)` is not the same as never having set it:
      # the key becomes present with a nil value, and every later reader that relied on a
      # default gets nil instead. That leaked out of this file and failed eighteen tests in
      # another one.
      restore(:cursor_store, previous)
      restore(:converged_cursor_store, converged)
      Stub.clear()
    end)

    :ok
  end

  test "the default is the legacy store, so a host that has not opted in is unchanged" do
    Application.delete_env(:ash_bpmn, :cursor_store)
    assert CursorStore.impl() == CursorStore.Legacy
  end

  test "every defaulted config read survives a key present with a nil value" do
    # The class, not the instance. `Config.get/2` exists because `get_env/3`'s default does
    # not fire for a present nil, and a test restoring captured-as-unset config writes exactly
    # that. Each of these looked correct at its own call site.
    for {key, default} <- [
          definition_loader: AshBpmn.DefinitionLoader.Default,
          queue: :bpmn,
          max_attempts: 5,
          trigger_max_depth: 5,
          nudge_resource_field: :resource,
          nudge_tenant_field: :organization_id
        ] do
      previous = Application.get_env(:ash_bpmn, key)
      Application.put_env(:ash_bpmn, key, nil)

      on_exit(fn -> restore(key, previous) end)

      assert apply(AshBpmn.Config, key, []) == default,
             "#{key} should fall back to its default when present-but-nil"
    end
  end

  test "a key explicitly set to nil still resolves to the legacy store" do
    # Not a hypothetical: `put_env(key, nil)` leaves the key *present*, so `get_env/3`'s
    # default never fires and the caller gets `nil.read/2`. Any test restoring configuration
    # it captured before setting writes exactly that.
    Application.put_env(:ash_bpmn, :cursor_store, nil)
    assert CursorStore.impl() == CursorStore.Legacy
  end

  describe "the dual phase" do
    setup do
      Application.put_env(:ash_bpmn, :cursor_store, CursorStore.Dual)
      Application.put_env(:ash_bpmn, :converged_cursor_store, Stub)
      :ok
    end

    test "the legacy value is what the sweep gets, even when the converged one disagrees" do
      # The asymmetry is the point: a lost cursor row is a stuck process instance, and a
      # stuck instance is silent. The converged store is being evaluated, not trusted.
      ctx = ctx()
      {:ok, legacy} = CursorStore.Legacy.read(nil, ctx)

      Stub.set((legacy || 0) + 9_999)

      assert {:ok, ^legacy} = CursorStore.Dual.read(nil, ctx)
    end

    test "a disagreement is emitted rather than raised" do
      ctx = ctx()
      {:ok, legacy} = CursorStore.Legacy.read(nil, ctx)
      Stub.set((legacy || 0) + 1)

      :telemetry.attach(
        "divergence-test",
        [:ash_bpmn, :cursor_store, :divergence],
        fn _e, measures, meta, _ -> send(self(), {:divergence, measures, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("divergence-test") end)

      CursorStore.Dual.read(nil, ctx)

      assert_received {:divergence, %{authoritative: _, converged: _}, %{phase: :read}}
    end

    test "agreement is silent, which is what lag-zero looks like" do
      ctx = ctx()
      {:ok, legacy} = CursorStore.Legacy.read(nil, ctx)
      Stub.set(legacy)

      :telemetry.attach(
        "no-divergence-test",
        [:ash_bpmn, :cursor_store, :divergence],
        fn _e, _m, _meta, _ -> send(self(), :divergence) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("no-divergence-test") end)

      CursorStore.Dual.read(nil, ctx)

      refute_received :divergence
    end

    test "a converged store that raises does not take the sweep down" do
      # It is the half under evaluation. Letting it fail the sweep would make adopting the
      # convergence riskier than not adopting it, which defeats the dual phase.
      Stub.raise_on_read()
      ctx = ctx()

      assert {:ok, _} = CursorStore.Dual.read(nil, ctx)
    end

    test "advancing writes both" do
      ctx = ctx()
      {:ok, _} = CursorStore.Legacy.read(nil, ctx)

      assert :ok = CursorStore.Dual.advance(nil, 4_242, ctx)
      assert Stub.advanced() == 4_242

      assert {:ok, 4_242} = CursorStore.Legacy.read(nil, ctx)
    end

    test "configuring the dual store with nothing to compare against is refused" do
      Application.delete_env(:ash_bpmn, :converged_cursor_store)

      assert_raise RuntimeError, ~r/no :converged_cursor_store/, fn ->
        CursorStore.Dual.advance(nil, 1, ctx())
      end
    end
  end

  # The tenant domain, because the trigger kinds are optional and only it registers a Cursor.
  # A cursor store test against a domain with no cursor would be testing the nil path.
  defp restore(key, nil), do: Application.delete_env(:ash_bpmn, key)
  defp restore(key, value), do: Application.put_env(:ash_bpmn, key, value)

  defp ctx do
    {:ok, resources} = AshBpmn.Resources.for_domain(AshBpmn.TenantTest.Domain)

    %{
      resources: resources,
      scope: %AshBpmn.Scope{
        AshBpmn.Scope.system(:sweep)
        | tenant: tenant(),
          domain: AshBpmn.TenantTest.Domain
      },
      event_source: AshBpmn.Test.EventSource
    }
  end

  defp tenant do
    case Process.get({__MODULE__, :tenant}) do
      nil ->
        id = Ecto.UUID.generate()
        Process.put({__MODULE__, :tenant}, id)
        id

      id ->
        id
    end
  end
end
