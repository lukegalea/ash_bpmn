# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.TimerJob do
  @moduledoc """
  Resource macro for the timer ledger — one row per timer the engine armed.

  This is an **audit record over Oban**, and it is emphatically **not a
  scheduler**. Nothing here holds a timer, wakes at a due date, retries, or
  decides when anything fires.

  ## Oban is the scheduler, and it stays the scheduler

  `Oban.Stager` already holds a job until its `scheduled_at`, promotes it from
  the leader only, never promotes it early, and retries it if the node running
  it dies. That is the hard part of scheduling and it is solved. Reimplementing
  any of it here would produce a second, worse clock that disagrees with the
  first, and the disagreement would surface as timers firing twice or not at
  all. So `due_at` on this row is a **record of what Oban was told**, never an
  instruction to anybody. Nothing reads it to decide when to act.

  ## The reason a row is still needed: Oban forgets

  `Oban.Plugins.Pruner` deletes `completed`, `cancelled` and `discarded` jobs
  once they are older than `max_age` — days, in most configurations. And a
  cancelled Oban job carries **no reason for its cancellation**: the row simply
  moves to the `cancelled` state, and `cancel_all_jobs/1` writes nothing about
  who asked or why.

  Put those two together and "why did this escalation never fire?" is
  unanswerable a week later. The job that would have fired has been pruned, and
  even before it was pruned it never held the one fact the question is about.
  That question gets asked about escalations and expiries more than about
  anything else in the engine, because a timer that silently did not fire looks
  exactly like a timer that was never armed.

  This row is what survives the pruner. It records which token, task and node
  the timer was for, what kind it was, when it was due, the Oban job id that
  carried it, how it ended, and — the field that justifies the whole resource —
  a `cancel_reason`, because that is the one thing Oban structurally cannot
  give us.

  ## Append-mostly, and never destroyed

  `create`, then exactly one terminal transition: `record_fired` or
  `record_cancelled`, each admitting only a `:scheduled` row. There is no
  destroy action. An audit record that can be deleted answers no question, and
  a timer ledger that outlives the pruner only to be tidied up by the
  application is the same gap wearing a different hat.

  The two transitions exclude each other, which loses a narrow race on purpose.
  `AshBpmn.Runtime.Oban.cancel_all/1` cancels only *pending* jobs, so a timer
  that was already executing when its cancel landed will run to completion and
  then fail to record its own firing. The row then says `:cancelled` while the
  process event log says `:timer_fired`, and the two together are the true
  history. The alternative — letting a fire overwrite a cancel — would mean a
  row's terminal state depends on which of two concurrent writers finished
  last, which is exactly the property an audit record must not have.

  ## The index, and the query it exists for

  The query worth optimising is **"show me every timer that was cancelled
  without firing"**. Not the fired ones: a fired timer left a `:timer_fired`
  process event and usually a visible effect, so it can be traced from either
  end. Not the scheduled ones: those are still in `oban_jobs`, where they can
  be looked at directly. The cancelled ones are the set with no other evidence
  anywhere — Oban has forgotten them or will, and nothing else recorded the
  reason.

  That set is also a small minority of the table, which is why the index is
  **partial on `status = 'cancelled'`**: it stays proportional to the timers
  that were called off rather than to every timer the system has ever armed.

  ## Required options

    * `:domain` — the Ash domain.
    * `:repo` — the `AshPostgres.Repo`.

  ## Optional options

    * `:instance` — the Instance resource module, for a `belongs_to :instance`.
    * `:token` — the Token resource module, for a `belongs_to :token`.
    * `:task` — the HumanTask resource module, for a `belongs_to :task`.
      All three are optional and the row carries the ids either way, because a
      timer may belong to any subset of them: a catch timer has a token and no
      task, and a standalone approval's timer has a task and neither instance
      nor token.
    * `:table` — (default `"bpmn_timer_jobs"`).
    * `:tenant?` — (default `false`).
    * `:base` — the module to `use` in place of `Ash.Resource`, so the generated
      resource inherits a host application's base resource (ownership, audit,
      soft delete, tenancy, the policy set). See `AshBpmn.Resources.Base`.
    * `:base_opts` — options passed to `:base` verbatim, with `:domain` filled
      in. Ignored unless `:base` is set.
    * `:policies?` — emit the engine bypass policy (default `true`). Setting it
      to `false` hands the host the entire policy set, including whatever the
      engine needs to function. See `AshBpmn.Checks.AshBpmnInteraction`.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    instance = Keyword.get(opts, :instance)
    token = Keyword.get(opts, :token)
    task = Keyword.get(opts, :task)
    table = Keyword.get(opts, :table, "bpmn_timer_jobs")
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

      @ash_bpmn_kind :timer_job

      def ash_bpmn_kind, do: @ash_bpmn_kind

      postgres do
        table unquote(table)
        repo unquote(repo)

        custom_indexes do
          # Declared here rather than only in a migration because a host instantiating this
          # resource gets its schema from `mix ash.codegen`, and an index that exists only in
          # ash_bpmn's own test migrations would reach nobody's production database.
          #
          # Partial, on purpose. See the moduledoc: the cancelled timers are the only ones with
          # no other evidence anywhere, so they are the set worth an index, and they are a small
          # minority of the rows. Over the whole table this query is a scan of every timer ever
          # armed, nearly all of which fired uneventfully.
          #
          # Under attribute multitenancy AshPostgres prepends `organization_id` to the key list,
          # so the tenant copy comes out tenant-leading without being written twice.
          index [:due_at],
            where: "status = 'cancelled'",
            name: "#{unquote(table)}_cancelled_index"

          # The other direction: "what was armed for this task, and what became of it?" -- asked
          # from a task someone is looking at, which is how the forensic trail usually starts.
          index [:task_id]
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

        attribute :instance_id, :uuid do
          public? true
          description "The process instance. Nil for a standalone approval's timers."
        end

        attribute :token_id, :uuid do
          public? true
          description "The branch the timer was armed against. Nil for a standalone approval."
        end

        attribute :task_id, :uuid do
          public? true
          description "The human task the timer was armed for. Nil for a timer catch event."
        end

        attribute :node_id, :string do
          public? true
          description "The diagram node. Nil for a standalone approval, which has no diagram."
        end

        attribute :kind, :atom do
          constraints one_of: [:remind, :escalate, :expire, :catch]
          allow_nil? false
          public? true
        end

        # A record of what Oban was told, not an instruction to anyone. Nothing in this package
        # reads this column to decide when to act -- see the moduledoc.
        attribute :due_at, :utc_datetime_usec do
          allow_nil? false
          public? true
          description "The `scheduled_at` the Oban job was inserted with."
        end

        # Nullable because the insert can fail, and because a row written before the insert
        # returns has nothing to put here yet. A nil id is itself informative: it says the timer
        # was intended and no job carried it, which is a different failure from one that was
        # armed and cancelled.
        attribute :oban_job_id, :integer do
          public? true
          description "The Oban job that carried this timer, while that job still exists."
        end

        attribute :status, :atom do
          constraints one_of: [:scheduled, :fired, :cancelled]
          default :scheduled
          allow_nil? false
          public? true
        end

        attribute :fired_at, :utc_datetime_usec do
          public? true
          description "When the worker actually ran. Compare with `due_at` to see queue lag."
        end

        attribute :cancelled_at, :utc_datetime_usec do
          public? true
        end

        # The entire reason this resource exists. Oban's `cancelled` state carries no "why",
        # and without one a cancelled escalation is indistinguishable from one that was never
        # armed -- so this is required on the cancel transition rather than merely allowed.
        attribute :cancel_reason, :atom do
          constraints one_of: [
                        # The task reached a decision, so its clock stopped. The ordinary case,
                        # and worth recording precisely because it is ordinary: an auditor
                        # needs to see that the escalation stopped *because* somebody decided,
                        # not left to infer it from an absence.
                        :task_decided,
                        :task_cancelled,
                        # The branch was pruned out from under the timer -- an interrupting
                        # boundary event, a terminate end event, or a cancelled instance.
                        :token_consumed,
                        :instance_cancelled,
                        # The instance was restarted under another definition. Distinct from
                        # `:instance_cancelled` because the work is not over -- it is being
                        # done again by the successor, whose own timers are armed fresh -- and
                        # an auditor counting abandoned clocks must not count these.
                        :instance_superseded,
                        # A later arming of the same timer replaced this one. Kept distinct from
                        # the others because it is the only reason that means the clock is still
                        # running, just on a different row.
                        :superseded,
                        # The host cancelled it deliberately, for a reason this package has no
                        # vocabulary for. `data` is where the host says what it was.
                        :host_request
                      ]

          public? true
        end

        # Context the enumerated fields cannot carry: who asked for a host cancellation, which
        # row superseded this one. Deliberately not a second home for the facts above -- the
        # queryable columns stay queryable.
        attribute :data, :map do
          default %{}
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

      # Relationships are optional and never define their attribute: the ids above are the
      # record, and a host that has not passed the module still gets a complete row. Same shape
      # as `AshBpmn.Resources.Dispatch`, for the same reason.
      if unquote(instance) do
        relationships do
          belongs_to :instance, unquote(instance) do
            define_attribute? false
            allow_nil? true
            public? true
          end
        end
      end

      if unquote(token) do
        relationships do
          belongs_to :token, unquote(token) do
            define_attribute? false
            allow_nil? true
            public? true
          end
        end
      end

      if unquote(task) do
        relationships do
          belongs_to :task, unquote(task) do
            define_attribute? false
            allow_nil? true
            public? true
          end
        end
      end

      actions do
        read :read do
          primary? true
        end

        create :create do
          accept [
            :instance_id,
            :token_id,
            :task_id,
            :node_id,
            :kind,
            :due_at,
            :oban_job_id,
            :data
          ]
        end

        # Late-bound because the job id is only known once `Oban.insert/2` returns, and the row
        # may be written first so that a crash between the two leaves evidence rather than
        # nothing. Accepts only the id -- it is not a general-purpose update.
        update :attach_job do
          accept [:oban_job_id]
        end

        update :record_fired do
          accept [:data]
          require_atomic? false

          validate AshBpmn.Resources.TimerJob.StatusIsScheduled
          change set_attribute(:status, :fired)
          change set_attribute(:fired_at, &DateTime.utc_now/0)
        end

        update :record_cancelled do
          accept [:cancel_reason, :data]
          require_atomic? false

          validate AshBpmn.Resources.TimerJob.StatusIsScheduled
          # Required here rather than on the attribute, because a `:scheduled` row legitimately
          # has no cancel reason. The reason is required at the moment of cancelling, which is
          # the only moment anybody knows it.
          validate present(:cancel_reason)
          change set_attribute(:status, :cancelled)
          change set_attribute(:cancelled_at, &DateTime.utc_now/0)
        end
      end

      code_interface do
        define :create, action: :create
        define :attach_job, action: :attach_job, args: [:oban_job_id]
        define :record_fired, action: :record_fired
        define :record_cancelled, action: :record_cancelled, args: [:cancel_reason]
      end
    end
  end
end

defmodule AshBpmn.Resources.TimerJob.StatusIsScheduled do
  @moduledoc """
  Guards both terminal transitions: a timer ends exactly once.

  Reads `changeset.data.status` rather than `get_attribute/2` for the same reason every
  transition guard in this package does -- `get_attribute/2` would return the value the
  action's own `set_attribute` is about to write, which makes the guard self-satisfying.

  There is no re-read of the row inside the transaction here, unlike
  `AshBpmn.Resources.Token.EnsureStatusInDb`. A token claim must have exactly one winner
  because the loser would otherwise advance a process twice; two writers racing to terminate a
  timer row change nothing in the world, and the loser simply gets an error it is expected to
  ignore. Paying for a second read on every timer to tidy up a record would be the wrong trade.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status == :scheduled do
      :ok
    else
      {:error,
       field: :status,
       message: "timer is already #{changeset.data.status}; a timer ends exactly once"}
    end
  end
end
