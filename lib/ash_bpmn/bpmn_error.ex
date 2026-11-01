# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.BpmnError do
  @moduledoc """
  A business error an `ash:call` callable throws, for an error boundary event to catch.

  A service task's callee can fail two ways that look the same from outside. Postgres being
  unreachable is a fault: try again later. "The patient's insurer declined the claim" is an
  answer: trying again gets the same answer, and the diagram may say where to go next. Only
  the second may be caught, because catching a fault would route a transient outage down a
  branch that decides something.

  So a callee names the answer. The `ActionInvoker` path returns the tuple
  `{:error, {:bpmn_error, code, details}}`. An `ash:call` callable is an Ash action, and an
  Ash action's error has to be an Ash error, so it returns (or adds to its changeset) this
  exception instead:

      action :check_coverage, :map do
        argument :plan_id, :string, allow_nil?: false

        run fn input, _context ->
          if covered?(input) do
            {:ok, %{"covered" => true}}
          else
            {:error, AshBpmn.BpmnError.exception(code: "COVERAGE_DENIED", details: %{"plan" => "basic"})}
          end
        end
      end

  Either way the engine reads `{code, details}`. `code` is matched against the `errorCode` of
  the `bpmn:error` an error boundary on the task references. A match interrupts the task and
  leaves by the boundary's flow; no match is an unhandled error, and the instance fails at
  that task without retrying (see the "Business errors" section of `AshBpmn.ActionInvoker`).
  `details` is recorded, bounded, on the event that says what was caught.
  """

  use Splode.Error, fields: [:code, details: %{}], class: :invalid

  @type t :: %__MODULE__{code: String.t(), details: map()}

  @impl true
  def message(%{code: code}), do: "BPMN error #{code}"

  @doc """
  The business error carried by an invocation's failure, as `{code, details}`, or `nil` when
  the failure is anything else.

  Reads both shapes: the invoker's `{:bpmn_error, code, details}` and an Ash error class whose
  errors include an `AshBpmn.BpmnError`. A code that is neither a string nor an atom is not a
  code, so the failure stays a failure rather than becoming uncatchable by accident.
  """
  @spec from_failure(term()) :: {String.t(), map()} | nil
  def from_failure({:bpmn_error, code, details}), do: normalize(code, details)
  def from_failure(%__MODULE__{code: code, details: details}), do: normalize(code, details)

  def from_failure(%{__exception__: true, errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &from_failure/1)

  def from_failure(_), do: nil

  defp normalize(code, details) when is_binary(code) and code != "",
    do: {code, if(is_map(details), do: details, else: %{})}

  defp normalize(code, details) when is_atom(code) and code not in [nil, true, false],
    do: normalize(Atom.to_string(code), details)

  defp normalize(_code, _details), do: nil
end
