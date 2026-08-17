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
    * `:due_in` — duration keyword list e.g. `[hours: 48]` (optional)
    * `:escalate_in` — duration keyword list (optional)
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
    escalate_in = Keyword.get(opts, :escalate_in)
    expire_in = Keyword.get(opts, :expire_in)

    resources = DomainResolver.resolve!()
    resolver = Config.assignment_resolver!()

    subject = result
    actor = changeset.context[:actor]

    # Build resolver context
    resolver_ctx = %{
      subject: subject,
      actor: actor,
      instance: nil,
      task: nil,
      assigns: %{}
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

    filtered_candidates =
      Enum.reject(candidates, fn c -> c.id in exclusions end)

    subject_type = subject.__struct__ |> to_string()
    subject_id = subject.id

    # Calculate due_at
    due_at =
      if due_in do
        minutes = duration_to_minutes(due_in)
        DateTime.add(DateTime.utc_now(), minutes, :minute)
      else
        nil
      end

    # Check for a live approval before inserting. The partial unique index on
    # (subject_type, subject_id, node_id) where status in (open, claimed) is
    # still the real guard, but it can only report itself by aborting the
    # transaction — which unwinds past the rescue below rather than raising —
    # so the friendly error has to come from a read.
    if pending_approval?(resources, subject_type, subject_id, key) do
      {:error,
       Ash.Error.Changes.InvalidChanges.exception(
         fields: [:__approval__],
         message: "an approval for this action is already pending (key: #{key})"
       )}
    else
      insert_approval(resources, %{
        key: key,
        name: name,
        on_complete: on_complete,
        subject_type: subject_type,
        subject_id: subject_id,
        due_at: due_at,
        escalate_in: escalate_in,
        expire_in: expire_in,
        candidates: filtered_candidates,
        result: result
      })
    end
  end

  defp pending_approval?(resources, subject_type, subject_id, key) do
    resources.human_task
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_type == ^subject_type)
    |> Ash.Query.filter(subject_id == ^subject_id)
    |> Ash.Query.filter(node_id == ^key)
    |> Ash.Query.filter(status in [:open, :claimed])
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  defp insert_approval(resources, spec) do
    %{
      key: key,
      name: name,
      on_complete: on_complete,
      subject_type: subject_type,
      subject_id: subject_id,
      due_at: due_at,
      escalate_in: escalate_in,
      expire_in: expire_in,
      candidates: filtered_candidates,
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
            due_at: due_at
          },
          authorize?: false
        )

      # Materialize candidates
      Enum.each(filtered_candidates, fn c ->
        resources.task_candidate.create!(
          %{
            task_id: task.id,
            principal_type: c.type,
            principal_id: c.id
          },
          authorize?: false
        )
      end)

      # Schedule timers
      timer_job_ids = schedule_approval_timers(task.id, escalate_in, expire_in)

      if timer_job_ids != [] do
        resources.human_task.attach_timers!(task, timer_job_ids, authorize?: false)
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
        authorize?: false
      )

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

  defp schedule_approval_timers(task_id, escalate_in, expire_in) do
    ids = []

    ids =
      if escalate_in do
        minutes = duration_to_minutes(escalate_in)
        scheduled_at = DateTime.add(DateTime.utc_now(), minutes, :minute)

        {:ok, job} =
          AshBpmn.Runtime.Oban.insert(
            AshBpmn.Runtime.TimerWorker,
            %{
              "task_id" => task_id,
              "kind" => "escalate"
            },
            scheduled_at: scheduled_at
          )

        [job.id | ids]
      else
        ids
      end

    if expire_in do
      minutes = duration_to_minutes(expire_in)
      scheduled_at = DateTime.add(DateTime.utc_now(), minutes, :minute)

      {:ok, job} =
        AshBpmn.Runtime.Oban.insert(
          AshBpmn.Runtime.TimerWorker,
          %{
            "task_id" => task_id,
            "kind" => "expire"
          },
          scheduled_at: scheduled_at
        )

      [job.id | ids]
    else
      ids
    end
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
