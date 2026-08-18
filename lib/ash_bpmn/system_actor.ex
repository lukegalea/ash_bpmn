# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.SystemActor do
  @moduledoc """
  A named non-human actor, for engine work with no user behind it.

  Most of what this engine does is traceable to a person: someone started the
  instance, someone claimed the task, someone approved it. Some of it is not. A
  timer fires at 09:00 and cancels an unclaimed task; a sweep reactivates tokens
  after a deploy; the advance worker moves a token through three gateways while
  the person who triggered it is asleep.

  Passing `nil` as the actor for that work loses the distinction between "a
  background job did this" and "we did not record who did this", which are very
  different findings to anyone reading the audit trail afterwards. So background
  work carries one of these instead.

      AshBpmn.Scope.system(:timer)

  ## Deliberately not a resource

  There is no table and no runtime construction. A system actor is a compile-time
  constant: it has no lifecycle, nothing references it, and making it data would
  let someone mint new ones at runtime, which is exactly what makes the list
  worth auditing.
  """

  @type name :: :engine | :advance | :timer | :sweep
  @type t :: %__MODULE__{name: name(), description: String.t()}

  defstruct [:name, :description]

  @actors %{
    engine: "The ash_bpmn engine acting with no specific worker behind it.",
    advance: "The advance worker moving a token to its next node.",
    timer: "A task timer firing — escalation, reminder or expiry.",
    sweep: "The sweep worker recovering tokens stranded by a restart or deploy."
  }

  for {name, description} <- @actors do
    @doc "The `#{name}` system actor: #{description}"
    @spec unquote(name)() :: t()
    def unquote(name)(), do: %__MODULE__{name: unquote(name), description: unquote(description)}
  end

  @doc "All known system actors."
  @spec all() :: [t()]
  def all, do: Enum.map(Map.keys(@actors), &apply(__MODULE__, &1, []))

  @doc "The stable serialized form, for a host that persists actors to an audit log."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{name: name}), do: "ash_bpmn:#{name}"
end
