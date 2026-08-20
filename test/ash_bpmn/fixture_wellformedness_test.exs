defmodule AshBpmn.FixtureWellformednessTest do
  @moduledoc """
  Every BPMN fixture parses as *namespaced* XML, not merely as XML.

  `test/fixtures/business_rule.bpmn` did not. It used `xsi:type` on a
  `conditionExpression` and never declared `xmlns:xsi`, which is well-formed XML
  and not namespace-well-formed. Nothing noticed, because the compiler scans with
  `:xmerl` in its default non-namespace-aware mode, where an undeclared prefix is
  simply part of the attribute name.

  That is not a cosmetic difference. bpmn-js parses through moddle, which *is*
  namespace-aware, so a fixture the compiler accepts and executes can be a
  document the designer refuses to open. A test asserting well-formedness the way
  the compiler already parses would have passed on the broken file, so this one
  deliberately uses the stricter parser instead.
  """

  use ExUnit.Case, async: true

  @fixtures Path.wildcard("test/fixtures/*.bpmn") ++ Path.wildcard("dev/priv/*.bpmn")

  test "there are fixtures to check" do
    assert @fixtures != [], "expected BPMN fixtures to exist"
  end

  for fixture <- @fixtures do
    test "#{fixture} is namespace-well-formed" do
      xml = File.read!(unquote(fixture))

      result =
        try do
          {:ok, :xmerl_scan.string(String.to_charlist(xml), namespace_conformant: true)}
        catch
          :exit, reason -> {:error, reason}
          kind, reason -> {:error, {kind, reason}}
        end

      assert match?({:ok, _}, result),
             """
             #{unquote(fixture)} is not namespace-well-formed: #{inspect(result)}

             An XML prefix is most likely used without a matching xmlns: declaration on the
             root element. The compiler will not care; bpmn-js will.
             """
    end
  end
end
