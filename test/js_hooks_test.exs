# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.JsHooksTest do
  @moduledoc """
  `priv/js/hooks.js` must describe the hooks exactly: `events` names every
  event the hook passes to handleEvent (and nothing else), and each `load`
  points at a file that exists. A host that loads a hook lazily subscribes to
  `events` before the code arrives, so drift here silently drops events.
  """

  use ExUnit.Case, async: true

  @hooks_js "priv/js/hooks.js"
  @priv_js "priv/js"

  # One entry in hooks.js:  Name: { events: [...], load: () => import("./file.js") ...
  @hook_entry_re ~r{(\w+):\s*\{\s*events:\s*\[(.*?)\]\s*,\s*load:\s*\(\)\s*=>\s*import\(\s*(['"])(.*?)\3}s
  @string_re ~r/(['"])(.*?)\1/

  # handleEvent('name' / handleEvent("name" — the literal form.
  @handled_re ~r/handleEvent\(\s*(['"])(.*?)\1/

  # handleEvent(CONSTANT — the name lives in `const CONSTANT = "name"`.
  @constant_arg_re ~r/handleEvent\(\s*([A-Za-z_$][\w$]*)\s*[,)]/

  test "hooks.js parses into the package's hooks" do
    hooks = hooks()
    assert hooks != [], "no hooks parsed from #{inspect(@hooks_js)} — check the regex"
    assert Enum.uniq_by(hooks, & &1.name) == hooks, "duplicate hook names"
  end

  test "every event a hook handles is named in its events list" do
    for hook <- hooks() do
      handled = handled_events(hook)
      unlisted = Enum.sort(handled -- hook.events)

      assert unlisted == [],
             "#{hook.name} handles #{inspect(unlisted)} but its events list does not name them"
    end
  end

  test "the events list names only events the hook handles" do
    for hook <- hooks() do
      handled = handled_events(hook)
      unhandled = Enum.sort(hook.events -- handled)

      assert unhandled == [],
             "#{hook.name}'s events list names #{inspect(unhandled)} but the hook never handles them"
    end
  end

  test "every load points at a file that exists" do
    for hook <- hooks() do
      path = Path.join(@priv_js, hook.path)

      assert File.exists?(path),
             "#{hook.name}'s load imports #{inspect(hook.path)} but #{inspect(path)} does not exist"
    end
  end

  defp hooks do
    js = File.read!(@hooks_js)

    for [name, events_src, _quote, path] <-
          Regex.scan(@hook_entry_re, js, capture: :all_but_first) do
      events = Enum.map(Regex.scan(@string_re, events_src, capture: :all_but_first), &List.last/1)
      %{name: name, events: events, path: path}
    end
  end

  # The hook's slice of its source file: from `export const <Name>` to the next
  # top-level export, so hooks sharing one file (the designer and the viewer do)
  # are compared against their own handleEvent calls, not their neighbour's.
  defp handled_events(%{name: name, path: path}) do
    source = section(File.read!(Path.join(@priv_js, path)), name)

    assert source,
           "no `export const #{name}` found in #{inspect(path)} — hooks.js names a hook this file does not export"

    strings = Enum.map(Regex.scan(@handled_re, source, capture: :all_but_first), &List.last/1)

    constants =
      Regex.scan(@constant_arg_re, source, capture: :all_but_first)
      |> Enum.map(&List.last/1)
      |> MapSet.new()
      |> Enum.flat_map(&resolve_constant(source, &1))

    Enum.uniq(strings ++ constants)
  end

  defp section(source, hook_name) do
    marker = "export const #{hook_name}"

    case String.split(source, marker, parts: 2) do
      [_before, from_decl] ->
        [decl | _rest] = String.split(from_decl, ~r/\nexport const /, parts: 2)
        marker <> decl

      [_before] ->
        nil
    end
  end

  defp resolve_constant(source, name) do
    {:ok, re} = Regex.compile("(?:const|let|var)\\s+#{name}\\s*=\\s*(['\"])([^'\"]+)\\1", "s")

    case Regex.run(re, source, capture: :all_but_first) do
      [_quote, value | _] ->
        [value]

      nil ->
        flunk("handleEvent(#{name}) in the hook source resolves no `#{name} = \"...\"` constant")
    end
  end
end
