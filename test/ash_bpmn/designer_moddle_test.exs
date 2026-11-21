# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DesignerModdleTest do
  @moduledoc """
  The designer's moddle descriptor declares every `ash:timer` attribute the compiler reads.

  bpmn-js saves through moddle, and moddle writes back only what a descriptor declares: a
  timer whose `date` the descriptor did not know would come back from the designer with no
  moment, and the compiler would refuse it for having none. The static check runs everywhere;
  the round trip through bpmn-moddle itself runs where `dev/assets` has its node modules.
  """

  use ExUnit.Case, async: true

  @designer "priv/js/ash_bpmn_designer.js"

  test "every ash:timer attribute the compiler accepts is in the Timer descriptor" do
    declared = type_properties("Timer")

    for attr <- AshBpmn.Compiler.Timer.known_attributes() do
      assert attr in declared,
             "ash:timer #{attr} is read by the compiler but not declared in #{@designer}; " <>
               "the designer would drop it on save"
    end
  end

  test "the task schedule is declared and hangs off the task config" do
    assert "due" in type_properties("Schedule")
    assert "followUp" in type_properties("Schedule")
    assert "schedule" in type_properties("TaskConfig")
  end

  @tag :node
  test "a bpmn-moddle round trip keeps every timer and schedule attribute" do
    {output, status} =
      System.cmd("node", ["moddle_roundtrip.mjs"], cd: "dev/assets", stderr_to_stdout: true)

    assert status == 0, output
  end

  defp type_properties(name) do
    source = File.read!(@designer)

    [_, body] =
      Regex.run(
        ~r/name: '#{name}',\s*superClass: \['Element'\],\s*properties: \[(.*?)\]\s*\}/s,
        source
      )

    ~r/name: '(\w+)'/ |> Regex.scan(body) |> Enum.map(&List.last/1)
  end
end
