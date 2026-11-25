# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Changes.RequireApproval do
  @moduledoc """
  An Ash change that creates a standalone approval task after an action succeeds.

  ## Options

    * `:key` — unique approval key per subject+action while live (required)
    * `:name` — human-readable name for the approval task (required)
    * `:outcomes` — list of allowed outcome atoms (required)
    * `:candidates` — list of candidate specs for the resolver (required)
    * `:excluding` — list of exclusion specs (optional, default `[]`)
    * `:on_complete` — map of outcome => action ref string (optional)
    * `:due_in` — duration keyword list e.g. `[hours: 48]` (optional). Without it, a task
      with `:expire_in` takes the expiry instant as its `due_at`: that is its completion
      deadline.
    * `:follow_up_in` — duration keyword list (optional), written to `follow_up_at`. Like
      `due_at`, it is data for a host's board and triggers nothing.
    * `:remind_in` — duration keyword list (optional). Delivers a `:remind` notice through
      the configured `AshBpmn.TaskNotifier`.
    * `:escalate_in` — duration keyword list (optional). Asks the resolver's `escalate/2`
      whom to add (see "Escalation" in `AshBpmn.AssignmentResolver`).

  `:remind_in` needs a task notifier, and `:escalate_in` needs the resolver's `escalate/2`
  and a task notifier. Without them the approval is refused when it is created, and the
  action that requested it fails: a reminder or escalation nobody wired up would otherwise
  fire on schedule and tell nobody (DESIGN.md §11.8). This change has no publish step, so
  creation is where it is checked.
    * `:expire_in` — duration keyword list (optional)

  ## Example

      create :submit do
        accept [...]
        change AshBpmn.Changes.RequireApproval,
          key: "access_request.grant",
          name: "Approve access request",
          outcomes: [:approved, :rejected],
          candidates: [{:manager_of, "subject.created_by_id"}],
          excluding: ["subject.created_by_id"],
          on_complete: %{approved: "provision_access"},
          due_in: [hours: 48],
          escalate_in: [hours: 24],
          expire_in: [days: 7]
      end
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshBpmn.AssignmentResolver
  alias AshBpmn.Config
  alias AshBpmn.Runtime.DomainResolver

  @impl true
  def change(changeset, opts, _context) do
    # Store opts in changeset context for the after_action hook
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      # Store opts so after_action can access them
      Ash.Changeset.put_context(changeset, :ash_bpmn_approval_opts, opts)
    end)
    |> Ash.Changeset.after_action(fn changeset, result ->
      create_approval(changeset, result)
    end)
  end

  defp create_approval(changeset, result) do
    opts = changeset.context[:ash_bpmn_approval_opts] || %{}

    key = Keyword.fetch!(opts, :key)
    name = Keyword.fetch!(opts, :name)
    _outcomes = Keyword.fetch!(opts, :outcomes)
    candidate_specs = Keyword.fetch!(opts, :candidates)
    exclusion_specs = Keyword.get(opts, :excluding, [])
    on_complete = Keyword.get(opts, :on_complete, %{})
    due_in = Keyword.get(opts, :due_in)
    follow_up_in = Keyword.get(opts, :follow_up_in)
    escalate_in = Keyword.get(opts, :escalate_in)
    remind_in = Keyword.get(opts, :remind_in)
    expire_in = Keyword.get(opts, :expire_in)

    resources = DomainResolver.resolve!()
    resolver = Config.assignment_resolver!()

    case unwired_timers(resolver, remind_in, escalate_in) do
      [] ->
        create_wired_approval(changeset, result, resources, resolver, %{
          key: key,
          name: name,
          candidate_specs: candidate_specs,
          exclusion_specs: exclusion_specs,
          on_complete: on_complete,
          due_in: due_in,
          follow_up_in: follow_up_in,
          remind_in: remind_in,
          escalate_in: escalate_in,
          expire_in: expire_in
        })

      reasons ->
        {:error,
         Ash.Error.Changes.InvalidChanges.exception(
           fields: [:__approval__],
           message:
             "approval #{key} declares " <>
               Enum.join(reasons, " and ") <> "; see DESIGN.md §11.8"
         )}
    end
  end

  # Fail closed (DESIGN.md §11.8), at creation because a change has no publish step.
  defp unwired_timers(resolver, remind_in, escalate_in) do
    notifier = Config.task_notifier()

    [
      remind_in && is_nil(notifier) && "remind_in, but no task notifier is configured",
      escalate_in && is_nil(notifier) && "escalate_in, but no task notifier is configured",
      escalate_in &&
        not (Code.ensure_loaded?(resolver) and function_exported?(resolver, :escalate, 2)) &&
        "escalate_in, but the assignment resolver does not implement escalate/2"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp create_wired_approval(changeset, result, resources, resolver, opts) do
    %{
      key: key,
      name: name,
      candidate_specs: candidate_specs,
      exclusion_specs: exclusion_specs,
      on_complete: on_complete,
      due_in: due_in,
      follow_up_in: follow_up_in,
      remind_in: remind_in,
      escalate_in: escalate_in,
      expire_in: expire_in
    } = opts

    subject = result
    actor = changeset.context[:actor]

    # The approval belongs to whichever tenant the subject's own action was
    # running in. Taking it off the changeset rather than off `result` means a
    # host resource that scopes by something other than `organization_id` still
    # lands its approval in the right place.
    scope = %{
      AshBpmn.Scope.from_changeset(changeset)
      | domain: Ash.Resource.Info.domain(resources.human_task)
    }

    # Build resolver context. The same keys a diagram's user task hands the resolver:
    # `:tenant` to resolve in, and `:decisions`, empty here because a standalone approval has
    # no instance whose earlier tasks anyone decided.
    resolver_ctx = %{
      subject: subject,
      actor: actor,
      instance: nil,
      task: nil,
      assigns: %{},
      tenant: scope.tenant,
      decisions: %{}
    }

    # Normalized first: a resolver sees the same string-keyed maps here as it
    # does for a diagram-declared task, so hosts write one implementation.
    {:ok, candidates} =
      resolver.candidates(
        Enum.map(candidate_specs, &AssignmentResolver.normalize_candidate_spec/1),
        resolver_ctx
      )

    {:ok, exclusions} =
      resolver.exclusions(
        Enum.map(exclusion_specs, &AssignmentResolver.normalize_exclusion_spec/1),
        resolver_ctx
      )

    # As a diagram's user task: an empty set is answered by the host's
    # `no_eligible_candidate/2`, if it implements one.
    {filtered_candidates, unassignable} =
      AssignmentResolver.settle(
        resolver,
        Enum.reject(candidates, fn c -> c.id in exclusions end),
        %{
          node_id: key,
          candidate_specs:
            Enum.map(candidate_specs, &AssignmentResolver.normalize_candidate_spec/1),
          exclusion_specs:
            Enum.map(exclusion_specs, &AssignmentResolver.normalize_exclusion_spec/1),
          candidates: candidates,
          exclusions: exclusions
        },
        resolver_ctx
      )

    subject_type = subject.__struct__ |> to_string()
    subject_id = subject.id

    # One instant for every date the approval is created with, so `due_in` and `expire_in`
    # of the same length name the same moment.
    now = DateTime.utc_now()
    expires_at = expire_in && DateTime.add(now, duration_to_minutes(expire_in), :minute)

    # Without `due_in`, the expiry is the completion deadline, so it is the due date
    # (DESIGN.md §11.5), as it is for a diagram's user task with an expire timer.
    due_at =
      if due_in,
        do: DateTime.add(now, duration_to_minutes(due_in), :minute),
        else: expires_at

    follow_up_at = follow_up_in && DateTime.add(now, duration_to_minutes(follow_up_in), :minute)

    # Check for a live approval before inserting. The partial unique index on
    # (subject_type, subject_id, node_id) where status in (open, claimed) is
    # still the real guard, but it can only report itself by aborting the
    # transaction — which unwinds past the rescue below rather than raising —
    # so the friendly error has to come from a read.
    if pending_approval?(resources, subject_type, subject_id, key, scope) do
      {:error,
       Ash.Error.Changes.InvalidChanges.exception(
         fields: [:__approval__],
         message: "an approval for this action is already pending (key: #{key})"
       )}
    else
      insert_approval(resources, scope, %{
        key: key,
        name: name,
        on_complete: on_complete,
        subject_type: subject_type,
        subject_id: subject_id,
        due_at: due_at,
        follow_up_at: follow_up_at,
        now: now,
        remind_in: remind_in,
        escalate_in: escalate_in,
        expires_at: expires_at,
        candidates: filtered_candidates,
        exclusions: exclusions,
        unassignable: unassignable,
        result: result
      })
    end
  end

  defp pending_approval?(resources, subject_type, subject_id, key, scope) do
    resources.human_task
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_type == ^subject_type)
    |> Ash.Query.filter(subject_id == ^subject_id)
    |> Ash.Query.filter(node_id == ^key)
    |> Ash.Query.filter(status in [:open, :claimed])
    |> Ash.read!(AshBpmn.Scope.engine(scope))
    |> Enum.any?()
  end

  defp insert_approval(resources, scope, spec) do
    %{
      key: key,
      name: name,
      on_complete: on_complete,
      subject_type: subject_type,
      subject_id: subject_id,
      due_at: due_at,
      follow_up_at: follow_up_at,
      now: now,
      remind_in: remind_in,
      escalate_in: escalate_in,
      expires_at: expires_at,
      candidates: filtered_candidates,
      exclusions: exclusions,
      unassignable: unassignable,
      result: result
    } = spec

    # Create the human task (standalone — no instance_id/token_id)
    try do
      task =
        resources.human_task.create!(
          %{
            node_id: key,
            name: name,
            status: :open,
            on_complete: stringify_map_keys(on_complete),
            subject_type: subject_type,
            subject_id: subject_id,
            due_at: due_at,
            follow_up_at: follow_up_at,
            # Kept with the task so an excluded person cannot act through a candidate team.
            excluded_principal_ids: exclusions |> Enum.reject(&is_nil/1) |> Enum.uniq()
          },
          AshBpmn.Scope.engine(scope)
        )

      # Materialize candidates
      Enum.each(filtered_candidates, fn c ->
        resources.task_candidate.create!(
          %{
            task_id: task.id,
            principal_type: c.type,
            principal_id: c.id
          },
          AshBpmn.Scope.engine(scope)
        )
      end)

      # Schedule timers
      timer_job_ids =
        schedule_approval_timers(task.id, now, {remind_in, escalate_in, expires_at}, scope)

      if timer_job_ids != [] do
        resources.human_task.attach_timers!(task, timer_job_ids, AshBpmn.Scope.engine(scope))
      end

      # Record event
      resources.process_event.create!(
        %{
          kind: :task_created,
          task_id: task.id,
          data: %{
            "key" => key,
            "subject_type" => subject_type,
            "subject_id" => subject_id
          }
        },
        AshBpmn.Scope.engine(scope)
      )

      if unassignable do
        resources.process_event.create!(
          %{kind: :no_eligible_candidate, task_id: task.id, data: unassignable},
          AshBpmn.Scope.engine(scope)
        )
      end

      {:ok, result}
    rescue
      e ->
        # A concurrent request can still lose the race to the unique index.
        # Outside a transaction that surfaces as an exception; inside one the
        # data layer rolls back instead and this never runs.
        error_msg = friendly_constraint_error(e, key)

        if error_msg do
          {:error,
           Ash.Error.Changes.InvalidChanges.exception(fields: [:__approval__], message: error_msg)}
        else
          reraise e, __STACKTRACE__
        end
    end
  end

  defp friendly_constraint_error(%Ash.Error.Invalid{} = error, key) do
    message = Exception.message(error)

    # "has already been taken" is what AshPostgres turns a unique-index
    # violation into; the rest catch the raw Postgres wording.
    if message =~ "has already been taken" || message =~ "unique" ||
         message =~ "duplicate" || message =~ "constraint" do
      "an approval for this action is already pending (key: #{key})"
    else
      nil
    end
  end

  defp friendly_constraint_error(%{__struct__: module} = _error, _key)
       when module in [Ash.Error.Unknown, Postgrex.Error] do
    "an approval for this action is already pending"
  end

  defp friendly_constraint_error(_error, _key), do: nil

  # "index" is the timer's position among an approval's timers -- 0 for the escalation, 1 for
  # the expiry, 2 for the reminder -- which with the task id, its key and the repetition makes
  # the timer's key (DESIGN.md §11.4), as a diagram timer's position in its `ash:timers` does.
  defp schedule_approval_timers(task_id, now, {remind_in, escalate_in, expires_at}, scope) do
    [
      escalate_in &&
        {"escalate", 0, DateTime.add(now, duration_to_minutes(escalate_in), :minute)},
      expires_at && {"expire", 1, expires_at},
      remind_in && {"remind", 2, DateTime.add(now, duration_to_minutes(remind_in), :minute)}
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {kind, index, scheduled_at} ->
      {:ok, job} =
        AshBpmn.Runtime.Oban.insert(
          AshBpmn.Runtime.TimerWorker,
          AshBpmn.Scope.to_job_args(scope, %{
            "task_id" => task_id,
            "kind" => kind,
            "index" => index
          }),
          scheduled_at: scheduled_at
        )

      job.id
    end)
    |> Enum.reverse()
  end

  defp duration_to_minutes(opts) do
    Enum.reduce(opts, 0, fn
      {:minutes, n}, acc -> acc + n
      {:hours, n}, acc -> acc + n * 60
      {:days, n}, acc -> acc + n * 1440
    end)
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_map_keys(other), do: other
end
