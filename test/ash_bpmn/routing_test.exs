defmodule AshBpmn.RoutingTest do
  @moduledoc """
  The one router, and the three bugs that existed because there were three of them.

  `AshBpmn.Runtime.Routing` was extracted from `Interpreter.exclusive_gateway/4` so that the
  post-task path and the timer-expiry path could stop carrying their own divergent copies
  (engine hygiene #3 and #4). These tests pin the behaviour the copies got wrong, so a future
  fourth caller cannot quietly reintroduce it:

    * the declared `default=` is honoured (the facade's copy compared against flows carrying no
      `"id"`, so its default was dead code and never selected);
    * a FEEL `null` does not take a branch **and is reported** (the copy collapsed null into
      false, so nothing was ever recorded);
    * a FEEL `{:error, _}` propagates rather than degrading into "branch not taken" (the copy
      routed down `List.first(flows)` on an engine error);
    * and there is no first-flow fallback at all.

  These are unit tests over plain maps on purpose. The router is pure, the graph shape is the
  snapshot's, and a pure test of a routing decision is worth more than the same assertion made
  three integration layers away.
  """

  use ExUnit.Case, async: true

  alias AshBpmn.Runtime.Routing

  # The snapshot shape: flows keyed by id, each carrying from/to/condition.
  defp graph(flows, node_attrs \\ %{}) do
    %{
      "nodes" => %{"N" => Map.merge(%{"type" => "exclusiveGateway"}, node_attrs)},
      "flows" => flows
    }
  end

  defp feel(expr), do: %{"language" => "feel", "text" => expr}

  describe "outgoing/2" do
    test "injects the flow id, which is the whole reason the old default lookup failed" do
      g = graph(%{"f2" => %{"from" => "N", "to" => "B"}, "f1" => %{"from" => "N", "to" => "A"}})

      assert [%{"id" => "f1"}, %{"id" => "f2"}] = Routing.outgoing(g, "N")
    end

    test "is ordered stably, so evaluation order does not depend on map iteration" do
      g =
        graph(%{
          "c" => %{"from" => "N", "to" => "C"},
          "a" => %{"from" => "N", "to" => "A"},
          "b" => %{"from" => "N", "to" => "B"}
        })

      assert ["a", "b", "c"] = Enum.map(Routing.outgoing(g, "N"), & &1["id"])
    end

    test "ignores flows leaving other nodes" do
      g =
        graph(%{
          "mine" => %{"from" => "N", "to" => "A"},
          "theirs" => %{"from" => "OTHER", "to" => "B"}
        })

      assert ["mine"] = Enum.map(Routing.outgoing(g, "N"), & &1["id"])
    end
  end

  describe "choose/4 — conditions" do
    test "takes the first flow whose condition is true" do
      g =
        graph(%{
          "f1" => %{"from" => "N", "to" => "A", "condition" => feel("1 = 2")},
          "f2" => %{"from" => "N", "to" => "B", "condition" => feel("1 = 1")}
        })

      assert {:ok, %{flow: %{"id" => "f2", "to" => "B"}, nulls: []}} = Routing.choose(g, "N", %{})
    end

    test "stops at the first true condition rather than evaluating the rest" do
      g =
        graph(%{
          "f1" => %{"from" => "N", "to" => "A", "condition" => feel("1 = 1")},
          # Would raise if evaluated: `nope` is not in the context.
          "f2" => %{"from" => "N", "to" => "B", "condition" => feel("nope.missing = 1")}
        })

      assert {:ok, %{flow: %{"id" => "f1"}}} = Routing.choose(g, "N", %{})
    end
  end

  describe "choose/4 — the declared default" do
    test "is selected when no condition matched" do
      g =
        graph(
          %{
            "f1" => %{"from" => "N", "to" => "A", "condition" => feel("1 = 2")},
            "fdef" => %{"from" => "N", "to" => "D"}
          },
          %{"default_flow" => "fdef"}
        )

      assert {:ok, %{flow: %{"id" => "fdef", "to" => "D"}}} = Routing.choose(g, "N", %{})
    end

    test "does not win over a condition that is true" do
      g =
        graph(
          %{
            "f1" => %{"from" => "N", "to" => "A", "condition" => feel("1 = 1")},
            "fdef" => %{"from" => "N", "to" => "D"}
          },
          %{"default_flow" => "fdef"}
        )

      assert {:ok, %{flow: %{"id" => "f1"}}} = Routing.choose(g, "N", %{})
    end
  end

  describe "choose/4 — three-valued FEEL" do
    test "a null condition does not take the branch and is returned for recording" do
      # `subject.missing > 1` over a context without that path is null, not false. The
      # distinction is the point: a condition that is silently never true looks exactly like
      # one that is legitimately false, and is the worse bug.
      g =
        graph(%{
          "f1" => %{"from" => "N", "to" => "A", "condition" => feel("subject.missing > 1")},
          "f2" => %{"from" => "N", "to" => "B", "condition" => feel("1 = 1")}
        })

      assert {:ok, %{flow: %{"id" => "f2"}, nulls: [%{"id" => "f1"}]}} =
               Routing.choose(g, "N", %{"subject" => %{}})
    end

    test "nulls are still reported when nothing is selected at all" do
      g =
        graph(%{
          "f1" => %{"from" => "N", "to" => "A", "condition" => feel("subject.missing > 1")}
        })

      assert {:ok, %{flow: nil, nulls: [%{"id" => "f1"}]}} =
               Routing.choose(g, "N", %{"subject" => %{}})
    end

    test "false is an ordinary answer and is not reported as null" do
      g = graph(%{"f1" => %{"from" => "N", "to" => "A", "condition" => feel("1 = 2")}})

      assert {:ok, %{flow: nil, nulls: []}} = Routing.choose(g, "N", %{})
    end
  end

  describe "choose/4 — the fallback chain" do
    test "a gateway selecting nothing returns nil, so the caller can fail loudly" do
      g = graph(%{"f1" => %{"from" => "N", "to" => "A", "condition" => feel("1 = 2")}})

      assert {:ok, %{flow: nil}} = Routing.choose(g, "N", %{})
    end

    test "a single unconditioned flow is the continuation of an ordinary node" do
      g = graph(%{"f1" => %{"from" => "N", "to" => "A"}})

      assert {:ok, %{flow: %{"id" => "f1"}}} =
               Routing.choose(g, "N", %{}, fallback: :single_unconditioned)
    end

    test "the fallback is deliberately narrow: two flows is a decision, not a continuation" do
      # This is what stops the old `List.first(flows)` behaviour coming back. Two outgoing
      # flows and nothing selected means the diagram failed to say where the token goes, and
      # the engine must not invent an answer.
      g =
        graph(%{
          "f1" => %{"from" => "N", "to" => "A", "condition" => feel("1 = 2")},
          "f2" => %{"from" => "N", "to" => "B", "condition" => feel("1 = 2")}
        })

      assert {:ok, %{flow: nil}} = Routing.choose(g, "N", %{}, fallback: :single_unconditioned)
    end

    test "a single *conditioned* flow that answered false is not a continuation either" do
      g = graph(%{"f1" => %{"from" => "N", "to" => "A", "condition" => feel("1 = 2")}})

      assert {:ok, %{flow: nil}} = Routing.choose(g, "N", %{}, fallback: :single_unconditioned)
    end

    test "no outgoing flows at all is nil, not an error" do
      assert {:ok, %{flow: nil, outgoing: []}} =
               Routing.choose(graph(%{}), "N", %{}, fallback: :single_unconditioned)
    end
  end

  describe "choose/4 — engine errors versus FEEL semantics" do
    test "a malformed expression is null, not an error — FEEL has no exceptions" do
      # Worth pinning, because the instinct is that garbage should raise. It does not: an
      # erroneous FEEL expression evaluates to `null`, which is the specification's answer and
      # the same one `ash_decisions` had to learn against the DMN TCK. So a nonsense condition
      # does not take the branch and *is reported*, rather than propagating.
      g = graph(%{"f1" => %{"from" => "N", "to" => "A", "condition" => feel("this is not feel")}})

      assert {:ok, %{flow: nil, nulls: [%{"id" => "f1"}]}} = Routing.choose(g, "N", %{})
    end

    test "a non-boolean condition propagates instead of degrading into 'branch not taken'" do
      # `{:error, _}` is not a FEEL value. Collapsing it into false is how a process routes
      # itself down a path nobody chose; propagating it means the job retries and the instance
      # fails, which is the honest outcome.
      #
      # A condition evaluating to a non-boolean is the deterministic way to produce one --
      # `AshBpmn.Feel.evaluate_condition/3` calls that a modelling error rather than a false
      # branch. The other error sources it documents are a timeout and a malformed snapshot,
      # neither of which a unit test can manufacture cheaply, and the over-long-expression
      # guard lives in `compile/1` at publish time rather than on this path.
      g = graph(%{"f1" => %{"from" => "N", "to" => "A", "condition" => feel("1 + 1")}})

      assert {:error, reason} = Routing.choose(g, "N", %{})
      assert reason =~ "f1"
      assert reason =~ "not a boolean"
    end
  end

  describe "null_summary/1" do
    test "is empty for no nulls, so it can be appended unconditionally" do
      assert "" == Routing.null_summary([])
    end

    test "names the flows, because 'a condition was null' is not actionable" do
      summary = Routing.null_summary([%{"id" => "f1"}, %{"id" => "f2"}])

      assert summary =~ "2 condition(s)"
      assert summary =~ "f1"
      assert summary =~ "f2"
    end
  end
end
