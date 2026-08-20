# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Feel do
  @moduledoc """
  FEEL — the DMN expression language — as used by gateway conditions and business rule task
  inputs.

  This is the **only** module in the package that calls the engine, so replacing the engine is
  one module rather than a sweep across the compiler, the interpreter and the facade.

  ## Why FEEL, and what it replaced

  This package previously shipped `AshBpmn.Expr`: a hand-written tokenizer, recursive-descent
  parser and evaluator for a small boolean grammar. It was 571 lines to support
  `subject.amount > 100`, and it had two defects that a bespoke language tends to have.

  It called `String.to_atom/1` on path segments taken from tenant-authored BPMN XML. Atoms are
  never collected, so a tenant admin who published a process with enough distinct path segments
  could exhaust the atom table and take the node down. And its `eval/2` ended in a bare
  `rescue _ -> {:ok, false}`, so *every* evaluation failure — a typo, a type error, a missing
  field — silently became "this branch is not taken", which is indistinguishable from a
  condition that is legitimately false.

  FEEL is a specified language with a public conformance suite, a decimal numeric model, and
  an editor and modeller from the same vendor as the bpmn-js designer this package already
  embeds. Adopting it also means gateway conditions and DMN decision tables speak one language
  rather than two, which is what `usage-rules.md` rule 9 has always asked for.

  ## Three semantics changed, deliberately

  | `AshBpmn.Expr` | FEEL |
  |---|---|
  | equality is `==` | equality is `=` |
  | `"a" > "b"` is `false` | `"a" > "b"` is `true` (lexicographic) |
  | a missing path, or any error, is `false` | a missing path, or an error, is `null` |

  The third is the one that matters. `null` is not `false`: it means *this condition did not
  produce an answer*. A gateway still does not take the branch — but it now **records** that it
  did not, as a `:condition_null` process event, because a condition that is silently never
  true is exactly the bug you want to see rather than the one you want to hide.

  ### One sharp edge inside that, which is FEEL to spec

  The three-valued logic is not uniform across operators. `subject.missing > 100` is `null`,
  but `subject.missing = true` is plain **`false`** — equality against null is defined, so
  there is nothing undetermined about it.

  So an *ordering* comparison on a field the subject does not have leaves a `:condition_null`
  event to find, and an *equality* comparison on the same missing field takes the default
  branch silently. That is a real diagnostic gap and it is not one we can close without
  departing from the specification, so it is written down instead — here, and pinned by
  `AshBpmn.ConditionMigrationTest`.

  ## Expressions are stored as text, not as a parsed tree

  A compiled condition lives inside `Definition.graph`, and an instance pinned to that snapshot
  must keep evaluating it for as long as it runs — across engine upgrades. The engine's AST is
  tagged tuples containing `Decimal`s: expressive, but not JSON, and carrying no version of its
  own. So the snapshot stores the **source text**, which is what the author wrote and what the
  BPMN document already contains. Re-parsing pins nothing; storing a tree would pin a parser.

  **There is no parse cache here, and that is a considered omission rather than an oversight.**
  `Boxic.FEEL.evaluate/2` parses on every call, and every call in this package evaluates one
  short gateway condition once per token advance — a token advance that has already done
  several database round trips. Caching that would optimise the cheapest step in the sequence.
  `AshDecisions.Feel` *does* memoise, because a decision table evaluates a cell per rule per
  column on a single call and the arithmetic is entirely different. If gateway evaluation ever
  moves onto a hot path, the cache to copy is that one.

  What is *not* stored is the engine version that validated the expression at publish time. A
  definition therefore records what the author wrote but not what agreed it was valid, so an
  engine upgrade that narrowed the accepted grammar would surface as a runtime failure on a
  published definition rather than as a refused publish. Named here because it is the one part
  of this argument that is aspirational.

  ## Every expression is hostile input

  Conditions arrive in tenant-authored XML. Evaluation is therefore bounded rather than
  trusted: the source is size-limited at parse time, and evaluation runs in a task that is
  killed outright on timeout. The kill is deliberate — a pathological regex inside `matches()`
  does not yield, so a `receive` guard around it would wait forever alongside it.

  External functions are refused by the engine, which is also one of the DMN TCK cases it is
  known not to pass. The engine and the policy happen to agree, and that is worth stating
  because it means the refusal does not depend on us remembering to enforce it.
  """

  @default_timeout_ms 250
  @max_source_bytes 8_192

  @typedoc "A compiled condition as it is stored in a definition snapshot."
  @type stored :: %{required(String.t()) => String.t()}

  @doc """
  Checks that `source` is a well-formed FEEL expression and returns the form to store.

  Called at **publish time**, so a condition that cannot parse is a compile error naming the
  flow rather than a branch that is never taken at three in the morning.
  """
  @spec compile(String.t()) :: {:ok, stored()} | {:error, String.t()}
  def compile(source) when is_binary(source) do
    trimmed = String.trim(source)

    cond do
      trimmed == "" ->
        {:error, "expression is empty"}

      byte_size(trimmed) > @max_source_bytes ->
        {:error, "expression is #{byte_size(trimmed)} bytes, over the #{@max_source_bytes} limit"}

      true ->
        case Boxic.FEEL.parse(trimmed) do
          {:ok, _ast} -> {:ok, %{"language" => "feel", "text" => trimmed}}
          {:error, error} -> {:error, describe(error)}
        end
    end
  end

  @doc """
  Evaluates a stored condition as a gateway test.

  Returns `{:ok, true}` to take the branch, `{:ok, false}` for an ordinary false, `{:ok, nil}`
  when the expression produced no answer, and `{:error, reason}` for a failure that is *not*
  FEEL semantics — a timeout, an over-long expression, a malformed snapshot.

  The distinction is load-bearing and the caller must honour it: `nil` and `false` do not take
  the branch, and an `:error` must propagate so the job retries rather than routing the process
  down a path nobody chose.
  """
  @spec evaluate_condition(stored() | String.t() | nil, map(), keyword()) ::
          {:ok, boolean() | nil} | {:error, String.t()}
  def evaluate_condition(stored, context, opts \\ [])

  def evaluate_condition(nil, _context, _opts), do: {:ok, nil}

  def evaluate_condition(%{"text" => source}, context, opts),
    do: evaluate_condition(source, context, opts)

  def evaluate_condition(source, context, opts) when is_binary(source) do
    case evaluate(source, context, opts) do
      # FEEL is three-valued: a comparison against a missing path is null, not false.
      {:ok, result} when is_boolean(result) or is_nil(result) ->
        {:ok, result}

      # A condition that evaluates to a non-boolean is a modelling error, not a false branch.
      {:ok, other} ->
        {:error, "condition produced #{inspect(other)}, which is not a boolean"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Evaluates an expression against a context, bounded by a timeout.

  `context` is expected to hold string keys; use `to_feel_value/1` on anything coming from Ash.
  """
  @spec evaluate(String.t(), map(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def evaluate(source, context, opts \\ []) when is_binary(source) and is_map(context) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    task = Task.async(fn -> Boxic.FEEL.evaluate(source, context) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, value}} ->
        {:ok, value}

      # The engine reports an erroneous expression as an error value; FEEL semantics make that
      # a null result rather than a failure, and the caller decides what a null branch means.
      {:ok, {:error, _error}} ->
        {:ok, nil}

      {:exit, reason} ->
        {:error, "evaluation crashed: #{inspect(reason)}"}

      nil ->
        {:error, "evaluation exceeded #{timeout}ms and was killed"}
    end
  end

  @doc """
  Renders a stored condition for a human — a properties panel, a diagram label, a process
  event, an error message.

  One-way by construction: the text *is* the source, so there is nothing to reconstruct and
  nothing to drift.
  """
  @spec print(stored() | String.t() | nil) :: String.t()
  def print(nil), do: ""
  def print(%{"text" => source}), do: source
  def print(source) when is_binary(source), do: source

  @doc """
  Converts an Ash record — or anything holding one — into a value FEEL can navigate.

  Three rules, and each is a decision rather than a convenience:

    * **Struct fields become string keys.** FEEL paths are `subject.amount`; a struct with atom
      keys cannot be navigated, and converting keys to atoms on the way *in* is what produced
      the atom-exhaustion defect this module replaced.
    * **Unloaded and forbidden fields are dropped, not nilled.** A dropped key is a missing path
      is `null` in FEEL, which is the honest answer: we do not know the value. Setting it to
      `nil` would assert that we do, and — for `Ash.ForbiddenField` — would quietly let a
      field the actor may not read influence which branch the process takes.
    * **Recursion is depth-bounded.** A loaded relationship graph can be large and cyclic;
      routing decisions do not need to see past a couple of hops.
    * **Integers and floats become `Decimal`.** FEEL's numeric model is decimal, and a literal
      in an expression parses to a `Decimal`. Leaving an Elixir integer in the context makes
      `subject.amount > 100` a type error, which FEEL folds to `null`, which a gateway reads
      as "branch not taken" — a wrong route with no error anywhere. This conversion is the
      difference between that and a working condition, and it is the reason a host must put
      everything through this function rather than handing the engine a map directly.
  """
  @spec to_feel_value(term(), non_neg_integer()) :: term()
  def to_feel_value(value, depth \\ 3)

  def to_feel_value(_value, depth) when depth < 0, do: nil
  def to_feel_value(nil, _depth), do: nil

  def to_feel_value(%Ash.NotLoaded{}, _depth), do: :__drop__
  def to_feel_value(%Ash.ForbiddenField{}, _depth), do: :__drop__

  # Numbers must arrive as Decimal or every comparison against a FEEL literal is a type error.
  # See the moduledoc; this is the single most consequential line in the module.
  def to_feel_value(value, _depth) when is_integer(value), do: Decimal.new(value)
  def to_feel_value(value, _depth) when is_float(value), do: Decimal.from_float(value)

  # Values the engine understands natively are passed through untouched.
  def to_feel_value(%Decimal{} = value, _depth), do: value
  def to_feel_value(%Date{} = value, _depth), do: value
  def to_feel_value(%Time{} = value, _depth), do: value
  def to_feel_value(%DateTime{} = value, _depth), do: value
  def to_feel_value(%NaiveDateTime{} = value, _depth), do: value

  def to_feel_value(%_struct{} = record, depth) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__, :__order__, :__lateral_join_source__])
    |> to_feel_value(depth)
  end

  def to_feel_value(map, depth) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case to_feel_value(value, depth - 1) do
        :__drop__ -> acc
        converted -> Map.put(acc, to_string(key), converted)
      end
    end)
  end

  def to_feel_value(list, depth) when is_list(list) do
    list
    |> Enum.map(&to_feel_value(&1, depth - 1))
    |> Enum.reject(&(&1 == :__drop__))
  end

  def to_feel_value(value, _depth) when is_atom(value) and not is_boolean(value),
    do: to_string(value)

  def to_feel_value(value, _depth), do: value

  defp describe(%{message: message}), do: message
  defp describe(other), do: inspect(other)
end
