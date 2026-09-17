# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Web.DesignerDraft do
  @moduledoc """
  Creating the designer's working draft without losing a race for it.

  Opening the designer on a key that has no draft yet creates one. That was a read followed by
  a create, which is not atomic: two people opening the same new process at the same moment
  both read `nil`, both insert, and the second hits the partial unique index on
  `(key, status) WHERE status = 'draft'`. The loser saw a crashed LiveView on a page that had
  done nothing wrong.

  Losing that race is not an error, because the thing the loser wanted now exists. So a
  conflict is resolved by reading again and using the winner's draft, which is also what makes
  the two users end up editing the same document rather than one of them editing a row the
  other cannot see.

  The recovery is narrow on purpose. Only a uniqueness error on this identity is treated as a
  lost race; anything else is re-raised, because a create that failed for some other reason is
  a real failure and swallowing it would put an empty designer in front of somebody with no
  indication that nothing was saved.

  That narrowness is defence in depth rather than load-bearing today, and the tests say so by
  not claiming to cover it: widening the check to treat every failure as a lost race does not
  change any observable outcome, because `reread!/4` re-raises the original error when it
  finds no winner. It becomes load-bearing the moment a re-read could succeed for a create
  that failed for an unrelated reason -- at which point the broad version would quietly hand
  back somebody else's draft and call the failure a race.
  """

  require Ash.Query

  @spec create_or_reread!(module(), String.t(), String.t(), keyword()) :: struct()
  def create_or_reread!(definition_mod, key, xml, opts) do
    definition_mod.create!(
      %{key: key, name: String.capitalize(key) <> " process", xml: xml},
      Keyword.put(opts, :authorize?, false)
    )
  rescue
    error in [Ash.Error.Invalid] ->
      if uniqueness_error?(error) do
        reread!(definition_mod, key, opts, error)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp reread!(definition_mod, key, opts, original) do
    definition_mod
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.do_filter(key: key, status: :draft)
    |> Ash.read_one!(opts)
    |> case do
      nil ->
        # The insert was rejected as a duplicate and the duplicate is not there. That is not a
        # race, it is a contradiction -- most likely a tenant mismatch between the write and
        # the read -- and inventing a draft to paper over it would hide it.
        raise original

      definition ->
        definition
    end
  end

  # Two ways to lose, and both count.
  #
  # `Definition` validates that no draft exists for the key before writing, which catches the
  # ordinary case and is itself a read-then-write -- so under real concurrency it can pass for
  # both callers and the partial unique index catches whoever commits second. The first
  # produces "a draft already exists for this key"; the second produces Ash's own "has already
  # been taken". Matching only one of them would leave the genuinely concurrent case
  # unhandled, which is precisely the case this module exists for.
  defp uniqueness_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %{field: :key, message: message} when is_binary(message) ->
        String.contains?(message, "already exists") or
          String.contains?(message, "already been taken")

      _ ->
        false
    end)
  end

  defp uniqueness_error?(_), do: false
end
