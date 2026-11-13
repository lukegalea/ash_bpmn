# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.Redrive do
  @moduledoc """
  Resource macro for re-driving failed trigger dispatches: one row per failed dispatch
  driven again, saying who asked, under which subscription version, and what came of it.

  The sweep records a dispatch it could not make as a `:failed` row and moves on
  (`AshBpmn.Resources.Dispatch`); nothing retries it by itself. `:redrive_failed` takes a
  range of a tenant's log, by event sequence, by when the events happened, or both, finds
  the failed start dispatches in it, and drives each again through `:record`, which runs
  the funnel again for that one event (`AshBpmn.Triggers.Redrive`).

  ## Under the version on the row

  A failed dispatch names the subscription version that failed, and that is the version
  driven again, whatever has been published since: a superseded version keeps the events
  up to its `retired_sequence`, and the funnel offers the event to no other. A version that
  is now disabled is not driven (`:not_started`, reason `"disabled"`): the switch is the
  operator's answer to "stop starting this".

  ## Starts once

  A re-drive does not count the `:failed` row as the record, and every other row still is,
  so a failure can become a start but never a second one (the dispatch identity excludes
  failed rows, not started ones). An event already started under the version records
  `:already_started` and runs nothing. Driving the same range twice is therefore safe: the
  second pass records what it found and starts nothing.

  ## Outcomes

    * `:started` - the funnel started the process; `dispatch_id` is its dispatch.
    * `:already_started` - the event had already started under the version; `dispatch_id`
      is that dispatch.
    * `:not_started` - nothing started. `reason` says why: `"disabled"`, `"event_not_found"`,
      or the reason on the row the funnel wrote this time (`"no_definition"`, say), or
      `"no_dispatch"` when its guard said a plain no.
    * `:no_authority` - the `:authority` callback refused; `reason` is what it returned.

  ## The host's authority check

  `:authority` is an optional `{module, function, args}` called before the funnel runs, as
  `apply(module, function, [subscription, tenant | args])`. It returns `:ok`, or
  `{:error, reason}` to record `:no_authority` with that reason and start nothing. A host
  whose versions run on an authority that can lapse (a grant held by the version's
  publisher, say) re-checks it here, so a re-drive never borrows the authority the version
  had when the event happened.

  ## A person's act

  The macro generates no engine bypass: nothing in the engine calls these actions, and a
  re-drive starts processes, so who may re-drive is the host's decision. Write the policies
  for `:record` and `:redrive_failed` (and `:read`); a resource with none forbids every
  call. The rows the engine reads to decide a re-drive (the dispatch, the version, the
  event) are read with the engine's mark, scoped to the action's tenant.

  `redriven_by_id` records the actor's id. A host whose base resource already records the
  creator can turn it off with `redriven_by?: false`.

  Append-only: `:record`, `:redrive_failed` and `:read`. A record of an act is never edited.

  ## In the BPMN domain

  The resource must live in the domain that holds the trigger resources
  (`AshBpmn.Resources.Subscription`, `AshBpmn.Resources.Dispatch`): the engine finds them
  there (`AshBpmn.Triggers.Resources.resolve!/1`).

  ## Options

    * `:domain` - **required**. The Ash domain this resource belongs to.
    * `:repo` - **required**. The `AshPostgres.Repo` for this resource.
    * `:table` - table name (default `"bpmn_redrives"`).
    * `:dispatch` - optional. The Dispatch resource module, for `belongs_to
      :failed_dispatch` and `belongs_to :dispatch` relationships. The rows carry the ids
      regardless.
    * `:subscription` - optional. The Subscription resource module, for a `belongs_to
      :subscription` relationship.
    * `:authority` - optional `{module, function, args}`. See above.
    * `:redriven_by?` - add `redriven_by_id`, set from the actor (default `true`).
    * `:tenant?` - set `true` to add `organization_id` multitenancy (default `false`).
    * `:base` - the module to `use` in place of `Ash.Resource`. See
      `AshBpmn.Resources.Base`.
    * `:base_opts` - options passed to `:base` verbatim, with `:domain` filled in.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "bpmn_redrives")
    dispatch = Keyword.get(opts, :dispatch)
    subscription = Keyword.get(opts, :subscription)
    authority = Keyword.get(opts, :authority)
    redriven_by? = Keyword.get(opts, :redriven_by?, true)
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

      @ash_bpmn_kind :redrive

      def ash_bpmn_kind, do: @ash_bpmn_kind

      postgres do
        table unquote(table)
        repo unquote(repo)

        custom_indexes do
          index [:failed_dispatch_id]
        end
      end

      if unquote(tenant?) do
        multitenancy do
          strategy :attribute
          attribute :organization_id
          global? true
        end
      end

      attributes do
        uuid_primary_key :id

        attribute :failed_dispatch_id, :uuid do
          allow_nil? false
          public? true
          description "The failed dispatch driven again."
        end

        attribute :subscription_id, :uuid do
          public? true

          description "The subscription version the failed dispatch names, and the re-drive used."
        end

        attribute :event_id, :uuid do
          public? true
          description "The event driven again."
        end

        attribute :event_sequence, :integer do
          public? true
          description "Its position in the tenant's log."
        end

        attribute :outcome, :atom do
          allow_nil? false
          public? true
          constraints one_of: [:started, :already_started, :not_started, :no_authority]
          description "What the re-drive did."
        end

        attribute :reason, :string do
          public? true

          description "Why nothing started: the dispatch's reason, the version's switch, or " <>
                        "what the authority check returned. Nil when it started."
        end

        attribute :dispatch_id, :uuid do
          public? true
          description "The dispatch that started the process, when one did or already had."
        end

        if unquote(redriven_by?) do
          attribute :redriven_by_id, :uuid do
            public? true
            writable? false
            description "Who drove it again: the actor's id."
          end
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

      if unquote(dispatch) do
        relationships do
          belongs_to :failed_dispatch, unquote(dispatch) do
            define_attribute? false
            allow_nil? false
            public? true
          end

          belongs_to :dispatch, unquote(dispatch) do
            define_attribute? false
            allow_nil? true
            public? true
          end
        end
      end

      if unquote(subscription) do
        relationships do
          belongs_to :subscription, unquote(subscription) do
            define_attribute? false
            allow_nil? true
            public? true
          end
        end
      end

      # Append-only: the record of an act is never edited, so there is no update and no
      # destroy to call.
      actions do
        read :read do
          primary? true
        end

        create :record do
          description "Drive one failed dispatch again, under the subscription version it names."
          accept [:failed_dispatch_id]

          change {AshBpmn.Resources.Redrive.Drive,
                  authority: unquote(authority), redriven_by?: unquote(redriven_by?)}
        end

        action :redrive_failed, {:array, :struct} do
          description "Drive again every failed dispatch whose event lies in a range of the " <>
                        "tenant's log, each under the version on its row."

          constraints items: [instance_of: __MODULE__]

          argument :from_sequence, :integer, description: "First event sequence, inclusive."
          argument :to_sequence, :integer, description: "Last event sequence, inclusive."

          argument :since, :utc_datetime_usec,
            description: "Events that happened at or after this instant."

          argument :until, :utc_datetime_usec,
            description: "Events that happened before this instant."

          run AshBpmn.Resources.Redrive.RedriveFailed
        end
      end

      code_interface do
        define :record, args: [:failed_dispatch_id]
        define :redrive_failed
      end
    end
  end
end

defmodule AshBpmn.Resources.Redrive.Drive do
  @moduledoc """
  Drives one failed dispatch again and records what came of it on the re-drive row
  (`AshBpmn.Triggers.Redrive.drive/3`).

  A `before_action` hook, so it runs after authorization: an actor the host's policies
  refuse re-drives nothing. It runs in the action's transaction, so the start, its dispatch
  row and the re-drive row commit together.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    case Keyword.get(opts, :authority) do
      nil ->
        {:ok, opts}

      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        {:ok, opts}

      other ->
        {:error, "`authority:` must be a {module, function, args} tuple, got: #{inspect(other)}"}
    end
  end

  @impl true
  def change(changeset, opts, context) do
    changeset
    |> record_actor(opts, context)
    |> Ash.Changeset.before_action(fn changeset ->
      id = Ash.Changeset.get_attribute(changeset, :failed_dispatch_id)

      case AshBpmn.Triggers.Redrive.drive(changeset.resource, id,
             tenant: changeset.tenant,
             authority: opts[:authority]
           ) do
        {:ok, attrs} ->
          Ash.Changeset.force_change_attributes(changeset, attrs)

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :failed_dispatch_id, message: message)
      end
    end)
  end

  defp record_actor(changeset, opts, context) do
    if Keyword.get(opts, :redriven_by?, true) do
      Ash.Changeset.force_change_attribute(changeset, :redriven_by_id, actor_id(context.actor))
    else
      changeset
    end
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil
end

defmodule AshBpmn.Resources.Redrive.RedriveFailed do
  @moduledoc """
  Finds the failed start dispatches whose event lies in a range of the tenant's log and
  drives each again through the resource's `:record`, as the calling actor.

  The range is by event sequence (`from_sequence`/`to_sequence`, inclusive), by when the
  events happened (`since` inclusive, `until` exclusive), or both. At least one bound is
  required: a re-drive of everything a tenant ever failed is not a thing to do by accident.

  One event that failed more than once has several failed rows; it is driven once, from its
  newest (`AshBpmn.Triggers.Redrive.failed/3`). Each re-drive is its own transaction, so
  the ones before a re-drive that errors stay done; the error stops the rest and is
  returned. On a multitenant resource a tenant is required, and only its dispatches are
  read.
  """

  use Ash.Resource.Actions.Implementation

  @bounds [:from_sequence, :to_sequence, :since, :until]

  @impl true
  def run(input, _opts, context) do
    bounds =
      for bound <- @bounds, into: %{}, do: {bound, Ash.ActionInput.get_argument(input, bound)}

    cond do
      Ash.Resource.Info.multitenancy_strategy(input.resource) && is_nil(input.tenant) ->
        {:error, "a re-drive needs a tenant"}

      Enum.all?(bounds, fn {_bound, value} -> is_nil(value) end) ->
        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             Ash.Error.Changes.InvalidArgument.exception(
               field: :from_sequence,
               message: "give a range: a sequence bound, a time bound, or both"
             )
           ]
         )}

      true ->
        input.resource
        |> AshBpmn.Triggers.Redrive.failed(input.tenant, bounds)
        |> redrive_each(input.resource, context)
    end
  end

  defp redrive_each(dispatches, resource, context) do
    opts = Ash.Context.to_opts(context)

    dispatches
    |> Enum.reduce_while([], fn dispatch, acc ->
      resource
      |> Ash.Changeset.for_create(:record, %{failed_dispatch_id: dispatch.id}, opts)
      |> Ash.create()
      |> case do
        {:ok, redrive} -> {:cont, [redrive | acc]}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      redrives -> {:ok, Enum.reverse(redrives)}
    end
  end
end
