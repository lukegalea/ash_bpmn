# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# Seeds the demo app with a published process and a few instances in different
# states, so the designer, viewer and task list all have something real to show.
#
#     mix dev.setup

require Ash.Query

alias AshBpmnDev.{AccessRequest, People}
alias AshBpmnDev.Bpmn.{Definition, HumanTask, Instance}

xml = File.read!("dev/priv/access_request.bpmn")
requester = People.requester_id()

# ── The process definition ─────────────────────────────────────────────────
#
# Version 1 is published (instances run against it); the designer then edits a
# fresh draft, which is the state a designer screenshot should show.

published =
  case Definition.latest_published!("access_request") do
    [existing | _] ->
      IO.puts("access_request v#{existing.version} already published")
      existing

    [] ->
      definition =
        Definition.create!(%{
          key: "access_request",
          name: "Privileged access request",
          xml: xml
        })

      if definition.errors != [] do
        IO.puts("compile errors in dev/priv/access_request.bpmn:")
        Enum.each(definition.errors, &IO.inspect/1)
        raise "seed aborted — the demo diagram does not compile"
      end

      Definition.publish!(definition)
  end

IO.puts("published access_request v#{published.version}")

# The next draft, so /designer opens on an editable document rather than the
# blank template.
existing_draft =
  Definition
  |> Ash.Query.for_read(:read)
  |> Ash.Query.filter(key == "access_request")
  |> Ash.Query.filter(status == :draft)
  |> Ash.read_one!(authorize?: false)

unless existing_draft do
  Definition.create!(%{
    key: "access_request",
    name: "Privileged access request",
    xml: xml
  })

  IO.puts("created next draft")
end

# ── Instances ──────────────────────────────────────────────────────────────

open_instances =
  Instance
  |> Ash.Query.for_read(:read)
  |> Ash.read!(authorize?: false)

if open_instances == [] do
  # 1. A standard request, waiting on the manager. This is the row the task
  #    list screenshot shows.
  standard =
    AccessRequest.create!(%{
      role: "prod-db-readonly",
      justification: "Investigating the checkout latency regression",
      is_privileged: false,
      created_by_id: requester
    })

  {:ok, _} =
    AshBpmn.start_instance(AshBpmnDev.Bpmn, process: "access_request", subject: standard)

  # 2. A privileged request, forked into two parallel reviews.
  privileged =
    AccessRequest.create!(%{
      role: "prod-db-admin",
      justification: "Quarterly index rebuild",
      is_privileged: true,
      created_by_id: requester
    })

  {:ok, privileged_instance} =
    AshBpmn.start_instance(AshBpmnDev.Bpmn, process: "access_request", subject: privileged)

  # Claim one of the two parallel reviews, so the task list shows both an open
  # and a claimed item rather than a half-empty board.
  privileged_task =
    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^privileged_instance.id)
    |> Ash.Query.filter(node_id == "PrivilegedManagerApproval")
    |> Ash.read_one!(authorize?: false)

  {:ok, _} = AshBpmn.claim_task(privileged_task, actor: %{id: People.manager_of(requester)})

  # 3. A request that already ran to completion, so the viewer has a finished
  #    audit trail to render.
  finished =
    AccessRequest.create!(%{
      role: "staging-deploy",
      justification: "Release captain for this sprint",
      is_privileged: false,
      created_by_id: requester
    })

  {:ok, instance} =
    AshBpmn.start_instance(AshBpmnDev.Bpmn, process: "access_request", subject: finished)

  task =
    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.Query.filter(node_id == "ManagerApproval")
    |> Ash.read_one!(authorize?: false)

  manager = %{id: People.manager_of(requester)}
  {:ok, task} = AshBpmn.claim_task(task, actor: manager)

  {:ok, _} =
    AshBpmn.complete_task(task,
      outcome: :approved,
      comment: "Release captain rotation confirmed.",
      actor: manager
    )

  IO.puts("seeded 3 instances (1 waiting, 1 parallel, 1 completed)")
else
  IO.puts("#{length(open_instances)} instances already present")
end
