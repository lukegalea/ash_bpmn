# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.DesignerDraftTest do
  @moduledoc """
  Losing the race to create the designer's draft.

  Opening the designer on a key with no draft creates one, and that was a read followed by a
  create. Two people opening the same new process at the same moment both read nil and both
  insert; the partial unique index on `(key, status) WHERE status = 'draft'` rejects the
  second, and the loser got a crashed LiveView on a page that had done nothing wrong.
  """

  use AshBpmn.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Test.Definition
  alias AshBpmn.Web.DesignerDraft

  @xml File.read!("test/fixtures/linear.bpmn")

  test "the first caller creates the draft" do
    key = unique_key()

    definition = DesignerDraft.create_or_reread!(Definition, key, @xml, authorize?: false)

    assert definition.key == key
    assert definition.status == :draft
  end

  test "the loser gets the winner's draft rather than an exception" do
    # The conflict is produced directly rather than raced for, because the test sandbox runs
    # both sides on one connection and would serialise a real race out of existence. What is
    # exercised is the branch that matters: the insert genuinely violates the index, and the
    # recovery re-reads.
    key = unique_key()
    winner = DesignerDraft.create_or_reread!(Definition, key, @xml, authorize?: false)

    loser = DesignerDraft.create_or_reread!(Definition, key, @xml, authorize?: false)

    assert loser.id == winner.id,
           "the loser should be editing the winner's draft, not a second one"

    # And exactly one draft exists. Two would mean the index had not held, which is the
    # failure this is all about.
    drafts =
      Definition
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(key == ^key and status == :draft)
      |> Ash.read!(authorize?: false)

    assert length(drafts) == 1
  end

  test "a failure that is not a lost race is still raised" do
    # What this proves is that a non-race failure still surfaces. It does NOT prove the
    # narrowness of the uniqueness check: widening that to match everything leaves this test
    # green, because the re-read finds no winner and re-raises the original error either way.
    # The narrow check earns its place only where a re-read could succeed for an unrelated
    # failure, which this design does not currently allow.
    # An empty key fails `allow_nil?`/constraint checks, not the draft-exists rule, so it must
    # come straight back out.
    assert_raise Ash.Error.Invalid, fn ->
      DesignerDraft.create_or_reread!(Definition, "", @xml, authorize?: false)
    end
  end

  defp unique_key, do: "draft_race_#{System.unique_integer([:positive])}"
end
