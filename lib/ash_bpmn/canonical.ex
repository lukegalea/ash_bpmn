# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Canonical do
  @moduledoc """
  One canonical JSON form, and the digest taken over it.

  Two things in this package need to agree, byte for byte, about what a map "is": the
  in-flight state export (`AshBpmn.StateExport`), which digests the shape of a DSL element so
  a later version can be compared against it, and the migration classifier
  (`AshBpmn.Migration.Classifier`), which decides what to do with an in-flight instance by
  comparing those digests. Two implementations of one canonical form is how a verifier ends
  up disagreeing with reality about key order and nulls, so there is one.

  ## The form

    * Map keys are sorted by their string form, and atom keys become strings. A map is an
      unordered thing and a digest is not, so the order has to come from somewhere other than
      the map's internal layout — which changes with insertion order and with the Erlang
      release.
    * Lists keep their order. A list *is* ordered; sorting one would make two different
      diagrams digest the same.
    * `nil` is `null`, and a key whose value is `nil` is kept rather than dropped. Dropping it
      would make "absent" and "explicitly null" digest alike, and in a compiled BPMN graph
      those are different documents — `"condition" => nil` is an unconditional flow, a missing
      `"condition"` key is a node kind that cannot carry one.
    * Atoms become strings, so `:waiting` and `"waiting"` digest identically. Token status
      arrives as an atom from Ash and as a string from a JSON round trip, and it is the same
      fact both times.
    * `DateTime`, `NaiveDateTime` and `Date` become ISO 8601 strings.
    * Floats are refused. There is no float in a BPMN graph or in an exported token, and
      accepting one would mean picking a printed representation and being stuck with it; a
      digest that changes when the runtime's float formatting changes is not a digest.
      Anything else unrecognised is refused for the same reason: silently digesting
      `inspect/1` output would produce a stable-looking hash of a struct's field order.

  ## The digest

      "sha256:" <> lower_hex |> binary_part(0, 32)

  `sha256`, lower hex, truncated to 32 hex characters — 128 bits. The prefix names the
  algorithm so a later change of algorithm is visible in the value rather than inferred from
  its length, and the truncation is short enough to read in a diff. This is the same form
  `AshBpmn.Resources.Definition` already uses for `content_hash` except for the truncation and
  the prefix, and it is deliberately the form the enterprise provenance envelope specifies, so
  a host's `Provenance.Digest` can be a thin delegation rather than a second implementation.
  """

  @digest_hex_length 32

  @doc """
  The canonical JSON encoding of `term`, as a binary.

  Raises `ArgumentError` for anything outside the accepted set — see the module docs for why
  that is better than a lenient fallback.
  """
  @spec encode(term()) :: binary()
  def encode(term), do: IO.iodata_to_binary(encode_value(term))

  @doc """
  The digest of `term`'s canonical form: `"sha256:"` followed by 32 lower-hex characters.
  """
  @spec digest(term()) :: String.t()
  def digest(term) do
    hex =
      :sha256
      |> :crypto.hash(encode(term))
      |> Base.encode16(case: :lower)
      |> binary_part(0, @digest_hex_length)

    "sha256:" <> hex
  end

  @doc """
  The digest of `term`, or `nil` when there is nothing to digest.

  A digest of `nil`, `%{}` or `[]` would be a real hash of a real empty thing, and would make
  "this run had no inputs" indistinguishable from "this field was never captured". The two
  have to stay distinguishable, so absence stays absent.
  """
  @spec digest_or_nil(term()) :: String.t() | nil
  def digest_or_nil(empty) when empty in [nil, %{}, []], do: nil
  def digest_or_nil(term), do: digest(term)

  # ── encoding ──────────────────────────────────────────────────────────────

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_binary(value), do: encode_string(value)
  defp encode_value(value) when is_atom(value), do: encode_string(Atom.to_string(value))

  defp encode_value(%DateTime{} = value), do: encode_string(DateTime.to_iso8601(value))
  defp encode_value(%NaiveDateTime{} = value), do: encode_string(NaiveDateTime.to_iso8601(value))
  defp encode_value(%Date{} = value), do: encode_string(Date.to_iso8601(value))

  defp encode_value(%_struct{} = value) do
    raise ArgumentError,
          "AshBpmn.Canonical cannot encode #{inspect(value.__struct__)}; " <>
            "convert it to a map, a string or an integer first"
  end

  defp encode_value(value) when is_map(value) do
    pairs =
      value
      |> Enum.map(fn {k, v} -> {key_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [encode_string(k), ?:, encode_value(v)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp encode_value(value) when is_list(value) do
    [?[, value |> Enum.map(&encode_value/1) |> Enum.intersperse(?,), ?]]
  end

  defp encode_value(value) when is_float(value) do
    raise ArgumentError,
          "AshBpmn.Canonical refuses to encode the float #{inspect(value)}; " <>
            "a digest cannot depend on float formatting"
  end

  defp encode_value(value) do
    raise ArgumentError, "AshBpmn.Canonical cannot encode #{inspect(value)}"
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key) when is_integer(key), do: Integer.to_string(key)

  defp key_string(key) do
    raise ArgumentError, "AshBpmn.Canonical cannot use #{inspect(key)} as a map key"
  end

  # Jason is already a dependency and already produces RFC 8259 string escaping; borrowing it
  # for the leaf case means the escaping rules are not reimplemented here, where they would be
  # a second place for the line-separator escape (U+2028) to be got wrong. The ordering — the
  # part that actually makes the form canonical — stays above.
  defp encode_string(value), do: Jason.encode_to_iodata!(value)
end
