# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DefinitionDiscardTest do
  @moduledoc """
  `:discard` removes a draft and nothing else.

  A published or retired definition is pinned by the instances that ran it and is the record
  of what ran, so the action must never take one -- not by being called on it, and not by
  being called on a stale struct that was a draft when it was loaded and has been published
  since.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Test.Definition

  @xml File.read!("test/fixtures/linear.bpmn")

  defp draft!(key), do: Definition.create!(%{key: key, name: key, xml: @xml}, authorize?: false)

  defp rows(key) do
    Definition
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.filter(key == ^key)
    |> Ash.read!(authorize?: false)
  end

  defp unique_key, do: "discard_#{System.unique_integer([:positive])}"

  test "a draft is removed" do
    key = unique_key()
    draft = draft!(key)

    assert :ok = Definition.discard(draft, authorize?: false)
    assert rows(key) == []
  end

  test "a published definition is refused, and stays" do
    key = unique_key()
    published = key |> draft!() |> Definition.publish!(authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} = Definition.discard(published, authorize?: false)
    assert [%{status: :published}] = rows(key)
  end

  test "a stale draft struct cannot take the row it has since become" do
    key = unique_key()
    draft = draft!(key)
    Definition.publish!(draft, authorize?: false)

    # `draft` still says :draft, so the validation passes; the locked re-read refuses it.
    assert {:error, %Ash.Error.Invalid{} = error} = Definition.discard(draft, authorize?: false)
    assert Exception.message(error) =~ "draft"
    assert [%{status: :published}] = rows(key)
  end
end
