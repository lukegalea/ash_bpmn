# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Runtime.Promotion do
  @moduledoc """
  The one gate between a callee's outputs and the token's routing.

  A business rule task, an `ash:call` service task and a legacy invoker service
  task all promote declared signals onto the token, and they are gated by the same
  code on all three — this module is that code, called by the interpreter at each
  site. Naming it costs one file and makes "outputs reach the token only through
  one gate" a fact you can check rather than a convention you have to trust, the
  same argument `AshBpmn.Runtime.Routing` makes for routing.

  ## The contract

  `promote/3` takes the node's declared promote entries (the snapshot's `promote`
  list), the callee's raw result, and the node id for error messages. It returns
  `{:ok, routing}` — a string-keyed map of string values the caller merges onto the
  token's routing — or `{:error, message}`. It never raises, and the caller's
  convention on `{:error, _}` is to raise, so Oban retries and the instance fails
  after max_attempts.

  Three things stand between a raw result and the routing:

    * **Structs are normalised to plain maps, recursively**, before anything is
      looked up. A callee that hands back `%Assessment{}` is passing outputs, not
      pulling a protocol trick; without the normalisation the struct would flow
      through `Map.fetch/2` to the atom-key fallback, which enumerates it, and
      structs are not Enumerable. Value structs that mean something whole —
      `Decimal`, `Date`, `DateTime` — are preserved rather than flattened.
    * **A promote name may be a dotted path** (`from="urgent.probability"`),
      resolved one segment at a time through string keys and then atom keys, so a
      callee's atom-keyed nested result and the diagram's dotted name meet without
      anyone calling `String.to_atom/1` on diagram-authored text (iron law #10).
      A path through anything that is not a plain map — a preserved value struct,
      a scalar, a list — is simply absent.
    * **Only declared scalars are promoted.** A non-scalar is a structured error
      naming the node, the path and the value's type: a token carries routing,
      not business data. An absent path promotes nothing, or fails when the
      signal is `required`.
  """

  @max_signal_name_bytes 64
  @max_signal_value_bytes 256

  # Structs whose identity is the value — flattening them would turn something a
  # FEEL expression or an error message can name into an anonymous map.
  @value_structs [Decimal, Date, DateTime]

  # A promote entry as the snapshot stores it: the routing key, the output path it
  # reads (`from`, which may be dotted), and whether absence fails the node.
  @type promote_entry :: %{optional(binary()) => term()}

  @spec promote([promote_entry()], map(), String.t()) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, String.t()}
  def promote(entries, outputs, node_id) when is_list(entries) and is_map(outputs) do
    outputs = normalize(outputs)

    Enum.reduce_while(entries, {:ok, %{}}, fn signal, {:ok, acc} ->
      name = signal["name"]
      path = signal["from"] || name
      value = fetch_output(outputs, path)

      cond do
        value == :__absent__ and signal["required"] ->
          {:halt,
           {:error, "node #{node_id}: did not return required signal '#{name}' (path '#{path}')"}}

        value == :__absent__ ->
          {:cont, {:ok, acc}}

        not scalar?(value) ->
          {:halt,
           {:error,
            "node #{node_id}: signal '#{name}' (path '#{path}') is a #{value_type(value)} " <>
              "value, which is not a scalar; a token carries routing, not business data"}}

        byte_size(name) > @max_signal_name_bytes ->
          {:halt, {:error, "node #{node_id}: signal name '#{name}' is too long"}}

        byte_size(to_string_value(value)) > @max_signal_value_bytes ->
          {:halt, {:error, "node #{node_id}: signal '#{name}' has an over-long value"}}

        true ->
          {:cont, {:ok, Map.put(acc, name, to_string_value(value))}}
      end
    end)
  end

  # Recursively flatten struct results into plain maps so promotion can see inside
  # them. Maps and lists are walked; `@value_structs` are left alone.

  defp normalize(%mod{} = value) when mod in @value_structs, do: value
  defp normalize(%_mod{} = value), do: value |> Map.from_struct() |> normalize()

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {key, normalize(inner)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value), do: value

  # A dotted path walks plain maps only. The plain-map check is what keeps a
  # preserved value struct (a Date, say) from being enumerated by the atom-key
  # fallback: a struct matches `%{}`, but it is not a map you can walk.
  defp fetch_output(outputs, path) do
    path |> String.split(".") |> walk_path(outputs)
  end

  defp walk_path([segment], container), do: fetch_key(container, segment)

  defp walk_path([segment | rest], container) do
    case fetch_key(container, segment) do
      value -> if plain_map?(value), do: walk_path(rest, value), else: :__absent__
    end
  end

  # Look a segment up by string key, and fall back to scanning for an equivalent
  # atom key rather than calling `String.to_atom/1` on it. The segment comes out
  # of tenant-authored BPMN XML, and creating an uncollectable atom from that is
  # the exact defect the old expression language shipped with. The fallback finds
  # the pair and reads it apart rather than `find_value`-ing the value directly:
  # `false` and `nil` are honest scalar outputs, and `find_value` would take them
  # for "not found".
  defp fetch_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Enum.find(map, fn {other_key, _value} ->
               is_atom(other_key) and Atom.to_string(other_key) == key
             end) do
          {_other_key, value} -> value
          nil -> :__absent__
        end
    end
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp scalar?(value),
    do:
      is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) or
        is_struct(value, Decimal) or is_atom(value)

  # The refusal names the value's type, not its contents: a token carries routing,
  # and the message exists so the diagram's author knows which path to stop promoting.
  defp value_type(%mod{}), do: inspect(mod)
  defp value_type(value) when is_map(value), do: "map"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(value) when is_tuple(value), do: "tuple"
  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_number(value), do: "number"
  defp value_type(value) when is_atom(value), do: "atom"
  defp value_type(_value), do: "term"

  # Stored as strings so the token's jsonb round-trips to exactly what FEEL will
  # compare against, rather than to whatever the JSON encoder chose.
  defp to_string_value(nil), do: ""
  defp to_string_value(value) when is_boolean(value), do: to_string(value)
  defp to_string_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value), do: to_string(value)
end
