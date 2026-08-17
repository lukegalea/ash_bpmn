# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmnDev.People do
  @moduledoc """
  A hard-coded org chart for the demo.

  A real host would resolve this from its own user/role model — that is the
  whole point of the `AshBpmn.AssignmentResolver` seam. Ids are fixed so seeds
  and screenshots are reproducible run to run.
  """

  @people %{
    "11111111-1111-1111-1111-111111111111" => %{
      name: "Dana Okoro",
      title: "Platform Engineer",
      manager_id: "22222222-2222-2222-2222-222222222222"
    },
    "22222222-2222-2222-2222-222222222222" => %{
      name: "Priya Raman",
      title: "Engineering Manager",
      manager_id: "33333333-3333-3333-3333-333333333333"
    },
    "33333333-3333-3333-3333-333333333333" => %{
      name: "Marc Devlin",
      title: "Director of Engineering",
      manager_id: nil
    },
    "44444444-4444-4444-4444-444444444444" => %{
      name: "Sam Achterberg",
      title: "Security Officer",
      manager_id: "33333333-3333-3333-3333-333333333333"
    }
  }

  @security_team ["44444444-4444-4444-4444-444444444444"]

  @spec all() :: %{optional(String.t()) => map()}
  def all, do: @people

  @spec requester_id() :: String.t()
  def requester_id, do: "11111111-1111-1111-1111-111111111111"

  @spec security_team() :: [String.t()]
  def security_team, do: @security_team

  @spec name(String.t() | nil) :: String.t()
  def name(nil), do: "—"
  def name(id), do: get_in(@people, [id, :name]) || short(id)

  @spec manager_of(String.t()) :: String.t() | nil
  def manager_of(id), do: get_in(@people, [id, :manager_id])

  defp short(id), do: id |> to_string() |> String.slice(0, 8)
end
