# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.HumanTask do
  @moduledoc """
  Resource macro for BPMN human work items (user tasks and standalone approvals).

  ## Required options

    * `:domain` — the Ash domain.
    * `:repo` — the `AshPostgres.Repo`.
    * `:instance` — the Instance resource module.
    * `:token` — the Token resource module.

  ## Optional options

    * `:table` — (default `"bpmn_human_tasks"`).
    * `:tenant?` — (default `false`).
    * `:base` — the module to `use` in place of `Ash.Resource`, so the generated
      resource inherits a host application's base resource (ownership, audit,
      soft delete, tenancy, the policy set). See `AshBpmn.Resources.Base`.
    * `:base_opts` — options passed to `:base` verbatim, with `:domain` filled
      in. Ignored unless `:base` is set.
    * `:policies?` — emit the engine bypass policy (default `true`). Setting it
      to `false` hands the host the entire policy set, including whatever the
      engine needs to function. See `AshBpmn.Checks.AshBpmnInteraction`.
    * `:task_candidate` — the TaskCandidate resource module. When given, the
      task gets a `has_many :candidates` relationship to it. Omit it if your
      resource already declares one.

  ## What the generated resource gives a host's task board

    * **`read :awaiting_actor`** — the candidacy read: open tasks the actor is
      a candidate for (a `:user` row for them, or a `:team` row for one of
      their teams; see `c:AshBpmn.AssignmentResolver.team_ids/2`), and claimed
      tasks they hold. Neither includes a task that excludes the actor. With
      no actor, or an actor with no id, it returns nothing. The narrowing is a
      filter on the query (the private `:awaits_actor?` calculation, see
      `AshBpmn.Resources.HumanTask.AwaitsActor`), so `Ash.count/2`,
      `Ash.aggregate/3` and a counted page on an `:awaiting_actor` query agree
      with the read. A relationship aggregate that names `:awaiting_actor` as
      its `read_action` does not: Ash does not run read-action preparations
      for it, so it counts tasks that do not await the actor. It paginates (offset or
      keyset, optional). The filter uses the actor the query runs as, so a
      query built without one and read or counted with one still narrows.
      The candidate rows are matched with an `exists` over the
      TaskCandidate resource that is not authorized: TaskCandidate read
      policies do not apply to it. It only decides which tasks are returned,
      scoped to the task (`task_id == parent(id)`) and the actor's own ids;
      no candidate row is returned. The task read itself is authorized as
      usual.
    * **`calculate :outcomes`** — the outcomes the task's BPMN step declares
      (`<ash:outcomes>`), read from the definition the instance pinned, so a
      board can offer a picker. `nil` for a standalone approval: the outcomes
      a `RequireApproval` change declares are not stored on the task.
    * **`excluded_principal_ids`** — the principals maker-checker subtracted
      from the candidate set when the task was created. See
      `AshBpmn.Candidacy` for why the task keeps them.

  ## Engine-only actions

  `:claim`, `:complete` and `:delegate` refuse any caller but the engine (see
  `AshBpmn.Resources.HumanTask.EngineOnly`). They accept the assignee and the
  decider as plain inputs and check nobody's candidacy, so a policy that let a
  person run them directly would get around maker-checker. People act through
  `AshBpmn.claim_task/2`, `complete_task/2` and `delegate_task/2`, which make
  those checks and then run these actions as the engine.

  `:force_complete` is not engine-only, because an administrator's override
  may need it. It writes an outcome with no decider and checks nobody, so
  authorize it for administrators only.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    instance = Keyword.fetch!(opts, :instance)
    token = Keyword.fetch!(opts, :token)
    task_candidate = Keyword.get(opts, :task_candidate)
    table = Keyword.get(opts, :table, "bpmn_human_tasks")
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

      @ash_bpmn_kind :human_task

      def ash_bpmn_kind, do: @ash_bpmn_kind

      postgres do
        table unquote(table)
        repo unquote(repo)

        custom_indexes do
          index [:subject_type, :subject_id, :node_id],
            unique: true,
            where: "status IN ('open','claimed')"
        end
      end

      if unquote(tenant?) do
        multitenancy do
          strategy :attribute
          attribute :organization_id
          global? true
        end
      end

      # The engine's own writes. Without this the resource has an authorizer and
      # -- unless the host adds policies -- no way to satisfy it, which is why
      # every internal call used to pass `authorize?: false`. See
      # `AshBpmn.Checks.AshBpmnInteraction` for what this replaces and what it
      # deliberately does not claim to be.
      if unquote(policies?) do
        policies do
          bypass AshBpmn.Checks.AshBpmnInteraction do
            authorize_if always()
          end
        end
      end

      attributes do
        uuid_primary_key :id

        attribute :node_id, :string do
          allow_nil? false
          public? true
        end

        attribute :name, :string do
          allow_nil? false
          public? true
        end

        attribute :status, :atom do
          constraints one_of: [:open, :claimed, :completed, :cancelled]
          default :open
          allow_nil? false
          public? true
        end

        attribute :assignee_type, :atom do
          constraints one_of: [:user, :team]
          public? true
        end

        attribute :assignee_id, :uuid do
          public? true
        end

        attribute :claimed_at, :utc_datetime_usec do
          public? true
        end

        attribute :due_at, :utc_datetime_usec do
          public? true
        end

        # A string, not an atom. An outcome is declared per node in `ash:outcomes` --
        # modeller-authored text in tenant-supplied XML -- so there is no compile-time
        # `one_of` list to constrain an :atom against, and the only two ways to get an
        # atom out of that are `String.to_atom/1`, which is an unbounded atom table fed
        # by anyone who can edit a diagram, and `String.to_existing_atom/1`, which
        # succeeds or fails depending on what happens to have been loaded.
        #
        # Worse, it could not be read back at all: with no `one_of`, Ash's atom type
        # refuses to cast the stored string back into an atom on load, so any read that
        # touched a completed task -- `AshBpmn.instance_report/2` with it -- failed with
        # `cannot load "approved" as type ...`. Same defect, and same fix, as
        # `AshBpmn.Resources.Instance.outcome`. Storage is unchanged -- Ash writes both
        # to text, so existing rows become loadable with no migration.
        attribute :outcome, :string do
          public? true
        end

        attribute :decided_by_id, :uuid do
          public? true
        end

        attribute :delegated_from_id, :uuid do
          public? true
        end

        attribute :timer_job_ids, {:array, :integer} do
          default []
          public? true
        end

        attribute :comment, :string do
          public? true
        end

        attribute :on_complete, :map do
          default %{}
          public? true
        end

        attribute :subject_type, :string do
          public? true
        end

        attribute :subject_id, :uuid do
          public? true
        end

        # The principals maker-checker subtracted when the task was created. The
        # subtraction already removed their candidate rows; kept here as well so a
        # person excluded by id cannot act through a candidate team they belong to.
        # See `AshBpmn.Candidacy`.
        attribute :excluded_principal_ids, {:array, :uuid} do
          default []
          allow_nil? false
          public? true
        end

        if unquote(tenant?) do
          attribute :organization_id, :uuid do
            allow_nil? false
            public? true
            writable? false
          end
        end

        timestamps()
      end

      relationships do
        belongs_to :instance, unquote(instance) do
          public? true
        end

        belongs_to :token, unquote(token) do
          public? true
        end

        if unquote(task_candidate) do
          has_many :candidates, unquote(task_candidate) do
            destination_attribute :task_id
            public? true
          end
        end
      end

      calculations do
        calculate :outcomes,
                  {:array, :string},
                  {AshBpmn.Resources.HumanTask.DeclaredOutcomes, instance: unquote(instance)} do
          public? true
          description "The outcomes the task's BPMN step declares; nil for a standalone approval."
        end

        # The candidacy test the `:awaiting_actor` read filters on. A calculation so Ash builds
        # it for the actor the query runs as, and an expression so counts and aggregates over
        # the read apply it too. See `AshBpmn.Resources.HumanTask.AwaitsActor`.
        # Field policies do not hide it from that filter: Ash checks them for fields a query
        # loads or selects, and for refs in filters given as input, and the preparation's
        # filter is neither.
        calculate :awaits_actor?,
                  :boolean,
                  {AshBpmn.Resources.HumanTask.AwaitsActor, resource: __MODULE__} do
          public? false
        end
      end

      actions do
        read :read do
          primary? true
        end

        read :awaiting_actor do
          description "Open tasks the actor is a candidate for, and claimed tasks the actor holds."
          prepare AshBpmn.Resources.HumanTask.AwaitingActor
          pagination offset?: true, keyset?: true, countable: true, required?: false
        end

        create :create do
          accept [
            :instance_id,
            :token_id,
            :node_id,
            :name,
            :status,
            :assignee_type,
            :assignee_id,
            :due_at,
            :on_complete,
            :subject_type,
            :subject_id,
            :excluded_principal_ids
          ]
        end

        # `:claim`, `:complete` and `:delegate` decide who acts on a task, so only the engine
        # runs them (`AshBpmn.Resources.HumanTask.EngineOnly`). A person reaches them through
        # `AshBpmn.claim_task/2`, `complete_task/2` and `delegate_task/2`, which check
        # candidacy, holding and maker-checker exclusion first.
        update :claim do
          accept [:assignee_type, :assignee_id]
          require_atomic? false

          validate AshBpmn.Resources.HumanTask.EngineOnly
          validate AshBpmn.Resources.HumanTask.StatusIsOpen
          change AshBpmn.Resources.HumanTask.EnsureOpenInDb
          change set_attribute(:status, :claimed)
          change set_attribute(:claimed_at, &DateTime.utc_now/0)
        end

        update :complete do
          accept [:outcome, :comment, :decided_by_id]
          require_atomic? false

          validate AshBpmn.Resources.HumanTask.EngineOnly
          validate AshBpmn.Resources.HumanTask.StatusIsClaimed
          validate AshBpmn.Resources.HumanTask.RequireOutcome
          change AshBpmn.Resources.HumanTask.EnsureClaimedInDb
          change set_attribute(:status, :completed)
        end

        update :cancel do
          accept []
          require_atomic? false

          validate AshBpmn.Resources.HumanTask.StatusIsOpenOrClaimed
          change AshBpmn.Resources.HumanTask.EnsureOpenOrClaimedInDb
          change set_attribute(:status, :cancelled)
        end

        update :delegate do
          accept [:assignee_type, :assignee_id]
          require_atomic? false

          validate AshBpmn.Resources.HumanTask.EngineOnly
          validate AshBpmn.Resources.HumanTask.StatusIsClaimed
          change AshBpmn.Resources.HumanTask.EnsureClaimedInDb
          change AshBpmn.Resources.HumanTask.RecordDelegatedFrom
        end

        update :attach_timers do
          accept [:timer_job_ids]
        end

        update :force_complete do
          accept [:outcome]
          require_atomic? false

          validate AshBpmn.Resources.HumanTask.StatusIsOpenOrClaimed
          change AshBpmn.Resources.HumanTask.EnsureOpenOrClaimedInDb
          change set_attribute(:status, :completed)
          change set_attribute(:decided_by_id, nil)
        end
      end

      code_interface do
        define :create, action: :create
        define :claim, action: :claim
        define :complete, action: :complete
        define :cancel, action: :cancel
        define :delegate, action: :delegate, args: [:assignee_type, :assignee_id]
        define :force_complete, action: :force_complete, args: [:outcome]
        define :attach_timers, action: :attach_timers, args: [:timer_job_ids]
      end
    end
  end
end

defmodule AshBpmn.Resources.HumanTask.EngineOnly do
  @moduledoc """
  Refuses the action unless the engine is the caller.

  On `:claim`, `:complete` and `:delegate`. Those actions take the assignee and
  the decider as inputs and check nobody's candidacy; the checks live in
  `AshBpmn.claim_task/2`, `complete_task/2` and `delegate_task/2`, which run
  the actions with `AshBpmn.Scope.engine/2`. A host policy that admitted a
  person to the actions themselves would otherwise let them claim, decide or
  hand on a task they are not a candidate for, their own request included.

  The test is the private context flag `AshBpmn.Scope.engine/2` sets, the same
  one `AshBpmn.Checks.AshBpmnInteraction` reads. It holds whatever the host's
  policies say, `policies?: false` included. As that check's documentation
  says, it is not a boundary against code in the same application, which can
  set the flag itself: it stops a policy from opening these actions to people
  by accident.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if get_in(changeset.context, [:private, :ash_bpmn?]) == true do
      :ok
    else
      {:error,
       field: :status,
       message:
         "#{changeset.action.name} is run by the engine; call AshBpmn.claim_task/2, " <>
           "complete_task/2 or delegate_task/2, which check who may act"}
    end
  end
end

defmodule AshBpmn.Resources.HumanTask.RequireOutcome do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    outcome = Ash.Changeset.get_attribute(changeset, :outcome)

    if is_nil(outcome) do
      {:error, field: :outcome, message: "outcome is required to complete a task"}
    else
      :ok
    end
  end
end

defmodule AshBpmn.Resources.HumanTask.RecordDelegatedFrom do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    current_assignee_id =
      case changeset.data do
        nil -> nil
        data -> Map.get(data, :assignee_id)
      end

    Ash.Changeset.change_attribute(changeset, :delegated_from_id, current_assignee_id)
  end
end

defmodule AshBpmn.Resources.HumanTask.StatusIsOpen do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # The *current* status is on changeset.data. `get_attribute/2` would return
    # the value the action's own `set_attribute` is about to write, which makes
    # a transition guard trivially self-satisfying.
    if changeset.data.status == :open do
      :ok
    else
      {:error, field: :status, message: "task must be open to claim"}
    end
  end
end

defmodule AshBpmn.Resources.HumanTask.StatusIsClaimed do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status == :claimed do
      :ok
    else
      {:error, field: :status, message: "task must be claimed"}
    end
  end
end

defmodule AshBpmn.Resources.HumanTask.EnsureStatusInDb do
  @moduledoc """
  Re-reads the task row inside the action's transaction and refuses the transition unless it
  is still in one of the given statuses.

  The validations beside this read `changeset.data.status`, which is as stale as whenever the
  caller last loaded the row. That was tolerable while a task only ever moved because a person
  moved it; it stopped being tolerable when interrupting boundary events arrived, because a
  boundary firing and a person deciding are now genuinely concurrent, and both would pass a
  check against their own stale copy. The same defect, and the same fix, as
  `AshBpmn.Resources.Token.EnsureStatusInDb`.

  Applied to `:cancel`, `:complete` and `:force_complete` together on purpose: guarding only
  the cancel would let a completion overwrite a cancel that had already won. `:claim` and
  `:delegate` have it too.

  With `holder?: true` (on `:complete` and `:delegate`, through `EnsureClaimedInDb`) the
  guard also requires the row to still have the assignee the action started from. The engine
  checks the holder against a read that takes no lock, and a delegation leaves the task
  `:claimed`, so without this a completion racing a delegation could still be written after
  the task had passed to someone else.

  The re-read alone does not settle a race: two transactions can both read the row before
  either writes it. So the guard is also a filter on the UPDATE itself (`status IN (...)` in
  its WHERE clause). The second writer waits on the first's row lock, finds the row no longer
  matches, updates nothing and gets `Ash.Error.Changes.StaleRecord`. Of two concurrent claims,
  exactly one wins. The re-read stays because it gives the ordinary case, a stale struct
  after the other write has committed, an error that says what happened.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def init(opts) do
    if is_list(opts[:status]) and opts[:status] != [] do
      {:ok, opts}
    else
      {:error, "status must be a non-empty list of atoms"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    allowed = opts[:status]
    holder? = opts[:holder?] == true
    holder = {Map.get(changeset.data, :assignee_type), Map.get(changeset.data, :assignee_id)}

    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(status in ^allowed))
    |> filter_holder(holder?, holder)
    |> Ash.Changeset.before_action(fn changeset ->
      pk = Map.get(changeset.data, :id)

      if is_nil(pk) do
        changeset
      else
        scope = AshBpmn.Scope.from_changeset(changeset)

        current =
          changeset.resource
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(id == ^pk)
          |> Ash.read_one!(AshBpmn.Scope.engine(scope))

        cond do
          is_nil(current) or current.status not in allowed ->
            Ash.Changeset.add_error(changeset,
              field: :status,
              message:
                "task is no longer #{Enum.join(allowed, " or ")} (concurrent modification); " <>
                  "found #{inspect(current && current.status)}"
            )

          holder? and {current.assignee_type, current.assignee_id} != holder ->
            Ash.Changeset.add_error(changeset,
              field: :assignee_id,
              message:
                "task has passed to #{current.assignee_type} #{current.assignee_id} " <>
                  "(concurrent modification)"
            )

          true ->
            changeset
        end
      end
    end)
  end

  defp filter_holder(changeset, false, _holder), do: changeset

  defp filter_holder(changeset, true, {type, id}) when is_nil(type) or is_nil(id),
    do:
      Ash.Changeset.filter(
        changeset,
        Ash.Expr.expr(is_nil(assignee_type) and is_nil(assignee_id))
      )

  defp filter_holder(changeset, true, {type, id}),
    do:
      Ash.Changeset.filter(
        changeset,
        Ash.Expr.expr(assignee_type == ^type and assignee_id == ^id)
      )
end

defmodule AshBpmn.Resources.HumanTask.EnsureOpenOrClaimedInDb do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    AshBpmn.Resources.HumanTask.EnsureStatusInDb.change(
      changeset,
      [status: [:open, :claimed]],
      context
    )
  end
end

defmodule AshBpmn.Resources.HumanTask.EnsureOpenInDb do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    AshBpmn.Resources.HumanTask.EnsureStatusInDb.change(changeset, [status: [:open]], context)
  end
end

defmodule AshBpmn.Resources.HumanTask.EnsureClaimedInDb do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    # `:complete` and `:delegate`: also guarded on the holder the action started from.
    AshBpmn.Resources.HumanTask.EnsureStatusInDb.change(
      changeset,
      [status: [:claimed], holder?: true],
      context
    )
  end
end

defmodule AshBpmn.Resources.HumanTask.StatusIsOpenOrClaimed do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status in [:open, :claimed] do
      :ok
    else
      {:error, field: :status, message: "task must be open or claimed"}
    end
  end
end
