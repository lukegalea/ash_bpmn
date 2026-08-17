# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Expr do
  @moduledoc """
  BPMN condition expression language — tokenizer + recursive-descent parser + evaluator.

  Grammar:
      expr    := or
      or      := and ("or" and)*
      and     := not ("and" not)*
      not     := "not" not | cmp
      cmp     := path op literal | path "in" "[" literal ("," literal)* "]"
      op      := ">" ">=" "<" "<=" "==" "!="
      path    := ident ("." ident)*
      literal := integer | float | quoted-string | true | false
  """

  @doc """
  Parses an expression string into a JSON-able AST map.

  Returns `{:ok, ast}` or `{:error, message}` with position context.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    input = String.trim(input)

    case tokenize(input) do
      {:ok, tokens} ->
        case parse_expr(tokens, 0) do
          {:ok, ast, pos} ->
            if pos == length(tokens) do
              {:ok, ast}
            else
              {:error, "unexpected token at position #{pos}: #{inspect(Enum.at(tokens, pos))}"}
            end

          {:error, msg} ->
            {:error, msg}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  @doc """
  Evaluates a parsed AST against a context map.

  Returns `{:ok, boolean()}`. Missing path → comparison is `false`.
  Nil compares `==`/`!=` only. Numbers compare numerically with all ops.
  Strings compare with `==`/`!=` only (false otherwise).
  """
  @spec eval(map(), map()) :: {:ok, boolean()}
  def eval(ast, ctx) when is_map(ast) and is_map(ctx) do
    {:ok, do_eval(ast, ctx)}
  rescue
    _ -> {:ok, false}
  end

  # ── Tokenizer ────────────────────────────────────────────────────────────

  defp tokenize(input) do
    do_tokenize(input, 0, [])
  catch
    {:tokenize_error, msg} -> {:error, msg}
  end

  defp do_tokenize("", _pos, acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(<<"  ", rest::binary>>, pos, acc) do
    do_tokenize(String.slice(rest, 1, String.length(rest)), pos + 1, acc)
  end

  defp do_tokenize(<<" ", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, acc)
  end

  defp do_tokenize(<<"\t", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, acc)
  end

  defp do_tokenize(<<"\n", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, acc)
  end

  defp do_tokenize(<<"\r", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, acc)
  end

  # Two-char operators
  defp do_tokenize(<<">=", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 2, [{:op, ">="} | acc])
  end

  defp do_tokenize(<<"<=", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 2, [{:op, "<="} | acc])
  end

  defp do_tokenize(<<"==", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 2, [{:op, "=="} | acc])
  end

  defp do_tokenize(<<"!=", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 2, [{:op, "!="} | acc])
  end

  # Single-char operators
  defp do_tokenize(<<">", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, [{:op, ">"} | acc])
  end

  defp do_tokenize(<<"<", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, [{:op, "<"} | acc])
  end

  # Punctuation
  defp do_tokenize(<<"[", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, [{:lbracket} | acc])
  end

  defp do_tokenize(<<"]", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, [{:rbracket} | acc])
  end

  defp do_tokenize(<<",", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, [{:comma} | acc])
  end

  defp do_tokenize(<<".", rest::binary>>, pos, acc) do
    do_tokenize(rest, pos + 1, [{:dot} | acc])
  end

  # Double-quoted string
  defp do_tokenize(<<"\"", rest::binary>>, pos, acc) do
    case read_string(rest, ?\", pos + 1) do
      {:ok, str, new_pos, remaining} ->
        do_tokenize(remaining, new_pos, [{:literal, str} | acc])

      {:error, msg} ->
        throw({:tokenize_error, msg})
    end
  end

  # Single-quoted string
  defp do_tokenize(<<"'", rest::binary>>, pos, acc) do
    case read_string(rest, ?', pos + 1) do
      {:ok, str, new_pos, remaining} ->
        do_tokenize(remaining, new_pos, [{:literal, str} | acc])

      {:error, msg} ->
        throw({:tokenize_error, msg})
    end
  end

  # Identifiers and keywords
  defp do_tokenize(<<c::utf8, _rest::binary>> = input, pos, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    case read_ident(input, pos) do
      {ident, new_pos, remaining} ->
        token =
          case ident do
            "and" -> {:kw, "and"}
            "or" -> {:kw, "or"}
            "not" -> {:kw, "not"}
            "in" -> {:kw, "in"}
            "true" -> {:literal, true}
            "false" -> {:literal, false}
            _ -> {:ident, ident}
          end

        do_tokenize(remaining, new_pos, [token | acc])
    end
  end

  # Numbers
  defp do_tokenize(<<c::utf8, _rest::binary>> = input, pos, acc) when c in ?0..?9 do
    case read_number(input, pos) do
      {num, new_pos, remaining} ->
        do_tokenize(remaining, new_pos, [{:literal, num} | acc])
    end
  end

  # Negative numbers (leading minus before a digit)
  defp do_tokenize(<<"-", c::utf8, _rest::binary>> = input, pos, acc) when c in ?0..?9 do
    case read_number(input, pos) do
      {num, new_pos, remaining} ->
        do_tokenize(remaining, new_pos, [{:literal, num} | acc])
    end
  end

  defp do_tokenize(<<c::utf8, _rest::binary>>, pos, _acc) do
    throw({:tokenize_error, "unexpected character '#{[c]}' at position #{pos}"})
  end

  defp read_ident(input, pos) do
    do_read_ident(input, pos, [])
  end

  defp do_read_ident(<<c::utf8, rest::binary>>, pos, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    do_read_ident(rest, pos + 1, [c | acc])
  end

  defp do_read_ident(input, pos, acc) do
    {acc |> Enum.reverse() |> List.to_string(), pos, input}
  end

  defp read_number(input, pos) do
    do_read_number(input, pos, [])
  end

  defp do_read_number(<<c::utf8, rest::binary>>, pos, acc) when c in ?0..?9 do
    do_read_number(rest, pos + 1, [c | acc])
  end

  defp do_read_number(<<".", c::utf8, _rest::binary>> = input, pos, acc)
       when c in ?0..?9 do
    do_read_float(input, pos, acc)
  end

  defp do_read_number(input, pos, acc) do
    num = acc |> Enum.reverse() |> List.to_string() |> String.to_integer()
    {num, pos, input}
  end

  defp do_read_float(<<".", c::utf8, rest::binary>>, pos, acc) when c in ?0..?9 do
    # Push BOTH the dot and the first fractional digit (c was matched but
    # previously dropped, so "3.14" tokenized as 3.4).
    do_read_float_frac(rest, pos + 2, [c, ?. | acc])
  end

  defp do_read_float(<<".", rest::binary>>, pos, acc) do
    # Not a float, just integer + dot
    num = acc |> Enum.reverse() |> List.to_string() |> String.to_integer()
    {num, pos, <<".", rest::binary>>}
  end

  defp do_read_float_frac(<<c::utf8, rest::binary>>, pos, acc) when c in ?0..?9 do
    do_read_float_frac(rest, pos + 1, [c | acc])
  end

  defp do_read_float_frac(input, pos, acc) do
    num = acc |> Enum.reverse() |> List.to_string() |> String.to_float()
    {num, pos, input}
  end

  defp read_string(input, quote_char, pos) do
    do_read_string(input, quote_char, pos, [])
  end

  defp do_read_string(<<>>, _quote_char, pos, _acc) do
    {:error, "unterminated string starting at position #{pos - 1}"}
  end

  defp do_read_string(<<"\\", c, rest::binary>>, quote_char, pos, acc) do
    escaped =
      case c do
        ?n -> ?\n
        ?t -> ?\t
        ?r -> ?\r
        ?\\ -> ?\\
        ?' -> ?'
        ?" -> ?"
        other -> other
      end

    do_read_string(rest, quote_char, pos + 2, [escaped | acc])
  end

  defp do_read_string(<<c, rest::binary>>, quote_char, pos, acc) when c == quote_char do
    {:ok, acc |> Enum.reverse() |> List.to_string(), pos + 1, rest}
  end

  defp do_read_string(<<c::utf8, rest::binary>>, quote_char, pos, acc) do
    do_read_string(rest, quote_char, pos + 1, [c | acc])
  end

  # ── Parser (recursive descent) ───────────────────────────────────────────

  # expr := or
  defp parse_expr(tokens, pos), do: parse_or(tokens, pos)

  # or := and ("or" and)*
  defp parse_or(tokens, pos) do
    case parse_and(tokens, pos) do
      {:ok, left, pos} ->
        collect_or(tokens, pos, left)

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp collect_or(tokens, pos, acc) do
    case peek(tokens, pos) do
      {:kw, "or"} ->
        case parse_and(tokens, pos + 1) do
          {:ok, right, new_pos} ->
            new_acc = %{"or" => flatten_binary_op(acc, "or") ++ [right]}
            collect_or(tokens, new_pos, new_acc)

          {:error, msg} ->
            {:error, msg}
        end

      _ ->
        {:ok, acc, pos}
    end
  end

  # and := not ("and" not)*
  defp parse_and(tokens, pos) do
    case parse_not(tokens, pos) do
      {:ok, left, pos} ->
        collect_and(tokens, pos, left)

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp collect_and(tokens, pos, acc) do
    case peek(tokens, pos) do
      {:kw, "and"} ->
        case parse_not(tokens, pos + 1) do
          {:ok, right, new_pos} ->
            new_acc = %{"and" => flatten_binary_op(acc, "and") ++ [right]}
            collect_and(tokens, new_pos, new_acc)

          {:error, msg} ->
            {:error, msg}
        end

      _ ->
        {:ok, acc, pos}
    end
  end

  # not := "not" not | cmp
  defp parse_not(tokens, pos) do
    case peek(tokens, pos) do
      {:kw, "not"} ->
        case parse_not(tokens, pos + 1) do
          {:ok, inner, new_pos} ->
            {:ok, %{"not" => inner}, new_pos}

          {:error, msg} ->
            {:error, msg}
        end

      _ ->
        parse_cmp(tokens, pos)
    end
  end

  # cmp := path op literal | path "in" "[" literal ("," literal)* "]"
  defp parse_cmp(tokens, pos) do
    case parse_path(tokens, pos) do
      {:ok, path, pos} ->
        case peek(tokens, pos) do
          {:kw, "in"} ->
            parse_in_list(tokens, pos + 1, path)

          {:op, op} ->
            case parse_literal(tokens, pos + 1) do
              {:ok, lit, new_pos} ->
                {:ok, %{"cmp" => [path, op, lit]}, new_pos}

              {:error, msg} ->
                {:error, msg}
            end

          token ->
            {:error,
             "expected comparison operator or 'in' at position #{pos}, got: #{inspect(token)}"}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp parse_in_list(tokens, pos, path) do
    case peek(tokens, pos) do
      {:lbracket} ->
        case parse_literal(tokens, pos + 1) do
          {:ok, first, pos} ->
            case collect_in_literals(tokens, pos, [first]) do
              {:ok, literals, pos} ->
                case peek(tokens, pos) do
                  {:rbracket} ->
                    {:ok, %{"in" => [path, literals]}, pos + 1}

                  token ->
                    {:error, "expected ']' at position #{pos}, got: #{inspect(token)}"}
                end

              {:error, msg} ->
                {:error, msg}
            end

          {:error, msg} ->
            {:error, msg}
        end

      token ->
        {:error, "expected '[' at position #{pos}, got: #{inspect(token)}"}
    end
  end

  defp collect_in_literals(tokens, pos, acc) do
    case peek(tokens, pos) do
      {:comma} ->
        case parse_literal(tokens, pos + 1) do
          {:ok, lit, new_pos} ->
            collect_in_literals(tokens, new_pos, acc ++ [lit])

          {:error, msg} ->
            {:error, msg}
        end

      _ ->
        {:ok, acc, pos}
    end
  end

  # path := ident ("." ident)*
  defp parse_path(tokens, pos) do
    case peek(tokens, pos) do
      {:ident, first} ->
        case collect_path(tokens, pos + 1, [first]) do
          {:ok, parts, pos} ->
            {:ok, Enum.join(parts, "."), pos}

          {:error, msg} ->
            {:error, msg}
        end

      token ->
        {:error, "expected identifier at position #{pos}, got: #{inspect(token)}"}
    end
  end

  defp collect_path(tokens, pos, acc) do
    case peek(tokens, pos) do
      {:dot} ->
        case peek(tokens, pos + 1) do
          {:ident, next} ->
            collect_path(tokens, pos + 2, acc ++ [next])

          token ->
            {:error,
             "expected identifier after '.' at position #{pos + 1}, got: #{inspect(token)}"}
        end

      _ ->
        {:ok, acc, pos}
    end
  end

  # literal := integer | float | quoted-string | true | false
  defp parse_literal(tokens, pos) do
    case peek(tokens, pos) do
      {:literal, val} ->
        {:ok, val, pos + 1}

      token ->
        {:error, "expected literal at position #{pos}, got: #{inspect(token)}"}
    end
  end

  # ── Token helpers ─────────────────────────────────────────────────────────

  defp peek(tokens, pos) when pos < length(tokens), do: Enum.at(tokens, pos)
  defp peek(_tokens, _pos), do: nil

  defp flatten_binary_op(%{"or" => children}, "or"), do: children
  defp flatten_binary_op(%{"and" => children}, "and"), do: children
  defp flatten_binary_op(other, _op), do: [other]

  # ── Evaluator ─────────────────────────────────────────────────────────────

  defp do_eval(%{"or" => children}, ctx) do
    Enum.any?(children, &do_eval(&1, ctx))
  end

  defp do_eval(%{"and" => children}, ctx) do
    Enum.all?(children, &do_eval(&1, ctx))
  end

  defp do_eval(%{"not" => inner}, ctx) do
    not do_eval(inner, ctx)
  end

  defp do_eval(%{"cmp" => [path, op, literal]}, ctx) do
    case resolve_path(path, ctx) do
      {:ok, nil} ->
        # nil only supports == and !=
        case op do
          "==" -> literal == nil
          "!=" -> literal != nil
          _ -> false
        end

      {:ok, val} ->
        safe_compare(val, op, literal)

      :missing ->
        false
    end
  end

  defp do_eval(%{"in" => [path, literals]}, ctx) do
    case resolve_path(path, ctx) do
      {:ok, val} ->
        val in literals

      :missing ->
        false
    end
  end

  # ── Path resolution ──────────────────────────────────────────────────────

  defp resolve_path(path, ctx) do
    parts = String.split(path, ".")
    do_resolve(parts, ctx)
  end

  defp do_resolve([], val), do: {:ok, val}

  defp do_resolve([part | rest], ctx) when is_map(ctx) do
    val =
      if is_struct(ctx) do
        # Structs use Map.get on field atoms
        Map.get(ctx, String.to_atom(part))
      else
        # Regular maps: try atom key then string key
        case Map.get(ctx, part) do
          nil -> Map.get(ctx, String.to_atom(part))
          val -> val
        end
      end

    case val do
      nil when rest != [] -> :missing
      nil -> {:ok, nil}
      val -> do_resolve(rest, val)
    end
  end

  defp do_resolve(_parts, _ctx), do: :missing

  # ── Comparison semantics ────────────────────────────────────────────────

  defp safe_compare(val, "==", literal), do: val == literal
  defp safe_compare(val, "!=", literal), do: val != nil and val != literal

  defp safe_compare(val, op, literal) when is_number(val) and is_number(literal) do
    case op do
      ">" -> val > literal
      ">=" -> val >= literal
      "<" -> val < literal
      "<=" -> val <= literal
      _ -> false
    end
  end

  defp safe_compare(_val, _op, _literal), do: false
end
