# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DecisionResolver do
  @moduledoc """
  The host callback a `businessRuleTask` resolves to.

  Third of the three seams — `AshBpmn.ActionInvoker` for what a service task *does*,
  `AshBpmn.AssignmentResolver` for who a human task is *for*, and this for what a business rule
  task *decides* — and it exists for the same reason as the other two:

  > **The process graph orchestrates. It never decides, never validates, and never authorizes.**

  A decision table is business logic. Putting it inside the graph would mean it is enforced in
  one place and bypassed by every other caller, which is the defect the architectural line
  exists to prevent. So the graph carries a *reference* to a decision and nothing else; what a
  decision is, where it is stored, how it is versioned and who may change it belong entirely to
  the host.

  `ash_decisions` is the intended implementation, but nothing here depends on it. A host with
  three rules in a config file can implement this behaviour in twenty lines, and a host with a
  DMN authoring UI can implement it over that. Neither has to tell this package which.

  ## Configuration

      config :ash_bpmn, decision_resolver: MyApp.Bpmn.Decisions

  A document containing a `businessRuleTask` will not compile without one, and the error names
  the config key. That is deliberate: the alternative is publishing a process whose decision
  node fails at three in the morning on the first instance that reaches it.
  """

  @typedoc """
  What the engine knows when it asks for a decision.

  `:instance`, `:token` and `:node_id` identify the asking, which a host may want for its own
  audit record; `:subject`, `:actor` and `:tenant` are the same values every other seam
  receives.
  """
  @type context :: %{
          optional(:subject) => struct() | nil,
          optional(:actor) => term(),
          optional(:tenant) => term(),
          optional(:instance) => struct() | nil,
          optional(:token) => struct() | nil,
          optional(:node_id) => String.t()
        }

  @typedoc """
  What a decision returns.

  `:outputs` is the decision's own result and may be any shape. `:version` and `:rule_ids` are
  optional and exist for the process event: an auditor asking "why did this instance go that
  way" wants the version that decided and the rule that fired, and only the host knows them.
  """
  @type result :: %{
          required(:outputs) => map(),
          optional(:version) => term(),
          optional(:rule_ids) => [String.t()]
        }

  @doc """
  Evaluates the decision named by `ref` against already-resolved `inputs`.

  Inputs arrive resolved rather than as expressions, so the host is never asked to evaluate
  something on the engine's behalf — the graph declares `from="subject.total_amount"`, the
  engine evaluates it, and the resolver receives a value.

  Returning `{:error, _}` fails the node. That is the same convention `ActionInvoker` uses: the
  Oban job retries, and the instance fails after `max_attempts` rather than routing itself down
  a branch nobody chose.
  """
  @callback decide(ref :: String.t(), inputs :: map(), context :: context()) ::
              {:ok, result()} | {:error, term()}

  @doc """
  Whether `ref` names a decision that exists.

  Called by the compiler at **publish time**, so a `businessRuleTask` cannot be published
  against a decision that is not there. This queries, and that is fine — publishing is not an
  authorization decision, and the rule that policy checks must never query is about the
  per-request path, not about compilation.
  """
  @callback exists?(ref :: String.t()) :: boolean()

  @doc """
  Normalizes the shape a resolver may return.

  A host that has nothing to say about versions or rule ids can return a bare map of outputs,
  and it is treated as `%{outputs: map}`. Accepting both keeps the twenty-line implementation
  twenty lines.
  """
  @spec normalize_result(term()) :: {:ok, result()} | {:error, term()}
  def normalize_result(%{outputs: outputs} = result) when is_map(outputs),
    do: {:ok, Map.take(result, [:outputs, :version, :rule_ids])}

  def normalize_result(outputs) when is_map(outputs), do: {:ok, %{outputs: outputs}}

  def normalize_result(other),
    do: {:error, "decision resolver returned #{inspect(other)}; expected a map of outputs"}
end
