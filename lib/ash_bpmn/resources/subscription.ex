# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Resources.Subscription do
  @moduledoc """
  Resource macro for event subscriptions — the triggers extension's deployment
  artifact (TRD §4.1).

  A subscription declares that something happening in the host's event log
  should start a process. It copies the discipline `AshBpmn.Resources.Definition`
  uses, because it is as much a deployed artifact as a process is: it decides
  what the system does in response to a write, and "which version of that rule
  was in force in March" is a question someone will ask. So: `key`/`version`,
  draft → published → retired, publish one-way, and an instance-visible read
  path (`latest_published`, `by_key_version`) shaped exactly like the
  definition's.

  ## Options

    * `:domain` — **required**.  The Ash domain this resource belongs to.
    * `:repo` — **required**.  The `AshPostgres.Repo` for this resource.
    * `:table` — table name (default `"bpmn_subscriptions"`).
    * `:tenant?` — set `true` to add `organization_id` multitenancy (default `false`).
      The version sequence is per key *within the tenant*, which is the only
      spelling of "version 3" that means anything to more than one organization.
    * `:base` — the module to `use` in place of `Ash.Resource`. See
      `AshBpmn.Resources.Base`.
    * `:base_opts` — options passed to `:base` verbatim, with `:domain` filled
      in. Ignored unless `:base` is set.
    * `:policies?` — emit the engine bypass policy (default `true`). See
      `AshBpmn.Checks.AshBpmnInteraction`.

  ## `enabled` is not `status`, and disabling is not retroactive

  Publishing and retiring are deployment acts. Switching a misfiring
  subscription off at two in the morning is an operational one, and conflating
  them means the only way to stop a bad subscription is to publish a new
  version of it. So `enable`/`disable` are separate actions that touch nothing
  but the switch.

  **Disabling does not un-fire what is already behind the cursor.** Events that
  arrived while the subscription was enabled will still be dispatched when the
  sweep reaches them. That is the opposite of what everyone assumes and is
  stated here rather than discovered. `latest_published` keeps returning a
  disabled subscription for the same reason: it answers "what is deployed",
  not "what is switched on".

  ## Publish-time verification, in order

  Publishing runs the checks the sweep cannot afford to discover at three in
  the morning, each refusing with the offender named:

    1. `guard_feel` parses as FEEL and is boolean-valued. A guard whose
       boolean-ness cannot be determined from an empty context (a missing path
       under an ordering comparison — FEEL `null`) is *not* refused: that is a
       runtime fact, recorded per dispatch as `:guard_null`.
    2. `subject_of` and `correlation_key_feel` parse.
    3. `match_resource` is audited — the configured `AshBpmn.EventSource` must
       answer `audited?/1` with `true`. With no event source configured the
       publish refuses naming the missing config: a subscription is unusable
       without one.
    4. The cycle invariant: `match_resource` must not name an `ash_bpmn` or
       `ash_decisions` resource. Those domains write rows of their own, and a
       subscription matching one would start processes that feed it. `kind:
       :signal` is the one named exception — a `Signal` row is an event in the
       host's log ordered with everything else, and cycles through it are
       bounded by `Dispatch.depth`.
    5. `decision_key` exists, via the configured `AshBpmn.DecisionResolver` —
       the same check the compiler runs for a `businessRuleTask`, and
       config-gated the same way.

  On success the expressions are compiled to their **stored form** — source
  text, never a parsed tree, so an upgrade re-evaluates rather than breaks —
  and the FEEL engine that validated them is stamped alongside
  (`compiled.feel_engine`), the same entry `Definition.graph` carries.

  For `source: :start_event` subscriptions, the definition publisher upserts by
  `(definition_id, node_id)`; this resource carries the columns and leaves the
  upsert to its caller.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "bpmn_subscriptions")
    tenant? = AshBpmn.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshBpmn.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

      @ash_bpmn_kind :subscription

      def ash_bpmn_kind, do: @ash_bpmn_kind

      postgres do
        table unquote(table)
        repo unquote(repo)

        custom_indexes do
          # Definition parity: one draft per key, so a republish is a new
          # version rather than a silent overwrite.
          index [:key, :status], unique: true, where: "status = 'draft'"

          # The coarse key the sweep queries first. Stage one of the funnel is
          # a structural comparison on resource, action and action type, and
          # it runs against every event in the log.
          index [:match_resource]
        end
      end

      if unquote(tenant?) do
        multitenancy do
          strategy :attribute
          attribute :organization_id
          global? true
        end
      end

      # The engine's own writes. See `AshBpmn.Checks.AshBpmnInteraction` for
      # what this replaces and what it deliberately does not claim to be.
      if unquote(policies?) do
        policies do
          bypass AshBpmn.Checks.AshBpmnInteraction do
            authorize_if always()
          end
        end
      end

      attributes do
        uuid_primary_key :id

        attribute :key, :string do
          allow_nil? false
          public? true
        end

        attribute :version, :integer do
          allow_nil? false
          public? true
        end

        attribute :status, :atom do
          constraints one_of: [:draft, :published, :retired]
          default :draft
          allow_nil? false
          public? true
        end

        attribute :enabled, :boolean do
          default true
          allow_nil? false
          public? true

          description "Operational switch, separate from status. Not retroactive -- see the moduledoc."
        end

        attribute :source, :atom do
          constraints one_of: [:start_event, :standalone]
          default :standalone
          allow_nil? false
          public? true

          description "Where the subscription came from: a definition's start event, or a standalone trigger."
        end

        attribute :definition_id, :uuid do
          public? true
          description "Set when source is :start_event."
        end

        attribute :node_id, :string do
          public? true
          description "The start event's node id. Set when source is :start_event."
        end

        attribute :match_resource, :string do
          allow_nil? false
          public? true
          description "The coarse key the sweep matches first -- the resource, in the short form."
        end

        attribute :match_action, :atom do
          public? true
          description "Nil matches any action on the resource."
        end

        attribute :match_action_type, :atom do
          constraints one_of: [:create, :update, :destroy]
          public? true
          description "Nil matches any action type."
        end

        attribute :kind, :atom do
          constraints one_of: [:message, :signal]
          default :message
          allow_nil? false
          public? true

          description "A message subscription matches resource/action; a signal subscription matches signal_name."
        end

        attribute :signal_name, :string do
          public? true
          description "The emitted signal this subscription hears. Required when kind is :signal."
        end

        attribute :guard_feel, :string do
          public? true
          description "A FEEL boolean over the event context. Nil always passes."
        end

        attribute :subject_of, :string do
          allow_nil? false
          default "event.record_id"
          public? true

          description "FEEL over the event context, yielding the subject id to start the process for."
        end

        attribute :correlation_key_feel, :string do
          public? true

          description "FEEL over the event context, yielding the correlation key for catch-bearing definitions."
        end

        attribute :route_kind, :atom do
          constraints one_of: [:static, :decision]
          default :static
          allow_nil? false
          public? true
        end

        attribute :process_key, :string do
          public? true
          description "The process to start, when route_kind is :static."
        end

        attribute :decision_key, :string do
          public? true
          description "The DMN decision that chooses the process, when route_kind is :decision."
        end

        attribute :variable_mapping, :map do
          default %{}
          allow_nil? false
          public? true
          description "Process-variable name to FEEL expression over the event context."
        end

        attribute :max_starts_per_event, :integer do
          default 1
          allow_nil? false
          public? true

          description "Bounds fan-out when a routing decision uses a COLLECT hit policy. Exceeding it fails the dispatch."
        end

        attribute :lookback_minutes, :integer do
          default 0
          allow_nil? false
          public? true

          description "How far back a parked token may reach for events that arrived before it. Zero disables lookback."
        end

        # The stored compiled form, stamped at publish: each expression as
        # source text plus the FEEL engine that validated it. Source text, not
        # a parsed tree -- see `AshBpmn.Feel` for why an upgrade must
        # re-evaluate rather than break.
        attribute :compiled, :map do
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

      identities do
        identity :unique_key_version, [:key, :version]
      end

      actions do
        read :read do
          primary? true
        end

        read :latest_published do
          argument :key, :string do
            allow_nil? false
          end

          prepare AshBpmn.Resources.Subscription.FilterLatestPublished
        end

        create :create do
          accept [
            :key,
            :enabled,
            :source,
            :definition_id,
            :node_id,
            :match_resource,
            :match_action,
            :match_action_type,
            :kind,
            :signal_name,
            :guard_feel,
            :subject_of,
            :correlation_key_feel,
            :route_kind,
            :process_key,
            :decision_key,
            :variable_mapping,
            :max_starts_per_event,
            :lookback_minutes
          ]

          change AshBpmn.Resources.Subscription.NormalizeMatchResource
          change AshBpmn.Resources.Subscription.AssignVersion
          validate AshBpmn.Resources.Subscription.TargetPresent
          validate AshBpmn.Resources.Subscription.SignalNamePresent
          validate AshBpmn.Resources.Subscription.UniqueDraftCheck
        end

        update :publish do
          accept []
          require_atomic? false

          # Publish-time verification cannot run in SQL -- it lints FEEL and
          # queries the host -- so this action is deliberately not atomic, the
          # same waiver Definition.publish carries.
          validate attribute_equals(:status, :draft), message: "only a draft can be published"

          validate AshBpmn.Resources.Subscription.TargetPresent
          validate AshBpmn.Resources.Subscription.SignalNamePresent
          validate AshBpmn.Resources.Subscription.GuardFeel
          validate AshBpmn.Resources.Subscription.ExpressionsParse
          validate AshBpmn.Resources.Subscription.MatchAudited
          validate AshBpmn.Resources.Subscription.NotCyclic
          validate AshBpmn.Resources.Subscription.DecisionExists

          change set_attribute(:status, :published)
          change AshBpmn.Resources.Subscription.CompileExpressions
        end

        update :retire do
          accept []
          require_atomic? false

          validate attribute_equals(:status, :published),
            message: "only a published subscription can be retired"

          change set_attribute(:status, :retired)
        end

        # Separate from publish/retire on purpose: an operational switch, not
        # a deployment act. See the moduledoc on why disabling is not
        # retroactive.
        update :enable do
          accept []
          change set_attribute(:enabled, true)
        end

        update :disable do
          accept []
          change set_attribute(:enabled, false)
        end
      end

      code_interface do
        define :create, action: :create
        define :publish, action: :publish
        define :retire, action: :retire
        define :enable, action: :enable
        define :disable, action: :disable
        define :by_key_version, action: :read, get_by: [:key, :version], get?: true
        define :latest_published, action: :latest_published, args: [:key]
      end
    end
  end
end

defmodule AshBpmn.Resources.Subscription.ResourceName do
  @moduledoc """
  Resolving the resource name a subscription matches on.

  The `match_resource` column is a string, so it can be typed three ways and
  compared unequally to every event forever -- the silent-never-fires failure
  the publish-time audit check exists to prevent. A name is accepted in either
  the prefixed form (`"Elixir.MyApp.Finance.Payout"`) or the short form people
  type (`"MyApp.Finance.Payout"`), and stored in the short form.

  One thing this module deliberately does **not** settle: the spelling an
  adapter's event context uses for the same resource. `AshBpmn.EventSource`'s
  context contract leaves the resource short-name to the adapter, so the sweep
  that eventually compares stored rows against live events owns that
  normalization. Here the short `inspect/1` form is the canonical one because it
  is what a person types and what a properties panel shows.
  """

  @prefix "Elixir."

  @doc "Resolves a name in either form to its resource module, without creating an atom."
  @spec resolve(term()) :: {:ok, module()} | :error
  def resolve(name) when is_binary(name) do
    module =
      if String.starts_with?(name, @prefix) do
        String.to_existing_atom(name)
      else
        String.to_existing_atom(@prefix <> name)
      end

    if Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) do
      {:ok, module}
    else
      :error
    end
  rescue
    # Nothing has ever compiled a module by that name: a typo, and one that
    # would otherwise present as a subscription that quietly never matches.
    ArgumentError -> :error
  end

  def resolve(_name), do: :error

  @doc "The canonical stored form: the short name, as a person writes it."
  @spec canonical(module()) :: String.t()
  def canonical(module), do: inspect(module)

  @doc "A name with the `Elixir.` prefix stripped, for prefix comparisons."
  @spec short(String.t()) :: String.t()
  def short(name) when is_binary(name), do: String.replace_prefix(name, @prefix, "")
  def short(name), do: to_string(name)
end

defmodule AshBpmn.Resources.Subscription.AssignVersion do
  @moduledoc """
  Numbers a new subscription `max(version) + 1` for its key.

  The read goes through the changeset's own scope, so two tenants' version
  sequences are independent: a version number that means different things to
  different tenants is worse than no version number.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    key = Ash.Changeset.get_attribute(changeset, :key)
    resource = changeset.resource

    if is_nil(key) do
      changeset
    else
      max_version = fetch_max_version(resource, key, AshBpmn.Scope.from_changeset(changeset))
      Ash.Changeset.change_attribute(changeset, :version, max_version + 1)
    end
  end

  # Reads the resource it is changing, from inside an action the caller was
  # already authorized for -- so it runs as engine work in the changeset's own
  # tenant. Mirrors `AshBpmn.Resources.Definition.AssignVersion`.
  defp fetch_max_version(resource, key, scope) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(AshBpmn.Scope.engine(scope))
    |> case do
      nil -> 0
      record -> record.version
    end
  rescue
    _ -> 0
  end
end

defmodule AshBpmn.Resources.Subscription.NormalizeMatchResource do
  @moduledoc """
  Stores `match_resource` in the canonical short form.

  See `AshBpmn.Resources.Subscription.ResourceName`. Accepting a name in either
  form and storing one keeps the sweep's match a plain string comparison rather
  than a place where two spellings have to be reconciled once per event,
  forever. A name that does not resolve is left alone: `MatchAudited` reports
  it, and reporting it twice would be two errors for one mistake.
  """

  use Ash.Resource.Change

  alias AshBpmn.Resources.Subscription.ResourceName

  @impl true
  def change(changeset, _opts, _context) do
    case ResourceName.resolve(Ash.Changeset.get_attribute(changeset, :match_resource)) do
      {:ok, module} ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :match_resource,
          ResourceName.canonical(module)
        )

      :error ->
        changeset
    end
  end
end

defmodule AshBpmn.Resources.Subscription.UniqueDraftCheck do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    key = Ash.Changeset.get_attribute(changeset, :key)
    resource = changeset.resource

    if is_nil(key) do
      :ok
    else
      scope = AshBpmn.Scope.from_changeset(changeset)

      exists =
        try do
          resource
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(key == ^key and status == :draft)
          |> Ash.read_one!(AshBpmn.Scope.engine(scope))
          |> case do
            nil -> false
            _ -> true
          end
        rescue
          _ -> false
        end

      if exists do
        {:error, field: :key, message: "a draft already exists for this key"}
      else
        :ok
      end
    end
  end
end

defmodule AshBpmn.Resources.Subscription.TargetPresent do
  @moduledoc """
  The route must name something: `:static` a `process_key`, `:decision` a
  `decision_key`.

  Neither is not a disabled subscription -- it is a subscription that matches
  events and then has nothing to do with them, which shows up as a growing pile
  of `:skipped` dispatch rows rather than as a configuration error.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :route_kind) do
      :static ->
        if present?(Ash.Changeset.get_attribute(changeset, :process_key)) do
          :ok
        else
          {:error, field: :process_key, message: "route_kind :static needs a process_key"}
        end

      :decision ->
        if present?(Ash.Changeset.get_attribute(changeset, :decision_key)) do
          :ok
        else
          {:error, field: :decision_key, message: "route_kind :decision needs a decision_key"}
        end

      _ ->
        :ok
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_), do: true
end

defmodule AshBpmn.Resources.Subscription.SignalNamePresent do
  @moduledoc """
  A `:signal` subscription hears a signal by name; without one it matches
  nothing.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :kind) == :signal and
         blank?(Ash.Changeset.get_attribute(changeset, :signal_name)) do
      {:error, field: :signal_name, message: "a :signal subscription needs a signal_name"}
    else
      :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end

defmodule AshBpmn.Resources.Subscription.GuardFeel do
  @moduledoc """
  Publish-time lint of `guard_feel`: it must parse as FEEL and be
  boolean-valued.

  The parse is the same check the compiler runs on gateway conditions
  (`AshBpmn.Feel.compile/1`), for the same reason: an expression that cannot
  parse should fail when someone publishes it, not when a dispatch reaches it.

  Boolean-ness is a *lint*, not a proof, and the honest limit is FEEL's own
  three-valued logic: evaluated against an empty publish context, a guard over
  the event context produces `null` -- a missing path -- which is exactly what
  it would produce at dispatch time before the event fills the context in. So
  `null` is not refused; a null result at dispatch is recorded as a
  `:guard_null` dispatch row, which is the diagnostic that matters. What the
  lint *does* refuse is an expression that provably produces something else --
  a literal, an arithmetic result, a string.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :guard_feel) do
      nil -> :ok
      source -> lint(source)
    end
  end

  defp lint(source) do
    case AshBpmn.Feel.compile(source) do
      {:ok, _stored} ->
        boolean_lint(source)

      {:error, message} ->
        {:error, field: :guard_feel, message: "guard is not valid FEEL: #{message}"}
    end
  end

  defp boolean_lint(source) do
    case AshBpmn.Feel.evaluate(source, %{}) do
      {:ok, value} when is_boolean(value) ->
        :ok

      # FEEL null: a path the publish context does not have. The dispatch row
      # is where a null guard becomes visible, not the publish action.
      {:ok, nil} ->
        :ok

      {:ok, other} ->
        {:error,
         field: :guard_feel,
         message:
           "guard must be boolean-valued, but it produces #{inspect(other)}; " <>
             "a guard answers a yes/no question"}

      {:error, reason} ->
        {:error, field: :guard_feel, message: "guard could not be linted: #{reason}"}
    end
  end
end

defmodule AshBpmn.Resources.Subscription.ExpressionsParse do
  @moduledoc """
  Publish-time check that `subject_of` and `correlation_key_feel` parse as
  FEEL. No boolean-ness requirement -- a subject expression yields an id, not
  an answer.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    expressions = [
      {:subject_of, Ash.Changeset.get_attribute(changeset, :subject_of)},
      {:correlation_key_feel, Ash.Changeset.get_attribute(changeset, :correlation_key_feel)}
    ]

    Enum.reduce_while(expressions, :ok, fn {field, source}, acc ->
      case compile(source) do
        :ok ->
          {:cont, acc}

        {:error, message} ->
          {:halt, {:error, field: field, message: "#{field} is not valid FEEL: #{message}"}}
      end
    end)
  end

  defp compile(nil), do: :ok

  defp compile(source) do
    case AshBpmn.Feel.compile(source) do
      {:ok, _stored} -> :ok
      {:error, message} -> {:error, message}
    end
  end
end

defmodule AshBpmn.Resources.Subscription.MatchAudited do
  @moduledoc """
  Publish-time check that `match_resource` names a resource the configured
  `AshBpmn.EventSource` actually audits.

  The event log is not a change feed -- it is a feed of writes that went
  through audited actions -- so a subscription watching a resource that writes
  no events waits forever, silently. That failure is refused here, with the
  resource named, rather than discovered.

  With **no event source configured**, publish refuses naming the missing
  config rather than raising it: a subscription is unusable without one, and a
  raise inside a validation reads as a bug rather than as the refusal it is.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    name = Ash.Changeset.get_attribute(changeset, :match_resource)

    cond do
      is_nil(name) ->
        :ok

      is_nil(Application.get_env(:ash_bpmn, :event_source)) ->
        {:error,
         field: :match_resource,
         message:
           "no event source is configured, so nothing can be audited and this " <>
             "subscription could never fire. Set " <>
             "`config :ash_bpmn, event_source: MyApp.Audit.EventSource` -- a " <>
             "subscription is unusable without one"}

      true ->
        case AshBpmn.Resources.Subscription.ResourceName.resolve(name) do
          {:ok, module} -> audited?(module, name)
          :error -> {:error, not_a_resource(name)}
        end
    end
  end

  defp audited?(module, name) do
    source = Application.get_env(:ash_bpmn, :event_source)

    case safe_audited?(source, module) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         field: :match_resource,
         message:
           "#{name} is not audited, so it writes no events and this subscription " <>
             "would never fire. The event log is a feed of writes that went through " <>
             "an audited action, not of every change to a row"}

      {:error, reason} ->
        {:error,
         field: :match_resource,
         message:
           "could not ask the configured event source whether #{name} is audited: #{inspect(reason)}"}
    end
  end

  # An adapter that raises inside `audited?/1` must not turn the refusal into
  # an exception -- publishing an *unverifiable* match is the thing this check
  # exists to prevent, so the reason is reported instead.
  defp safe_audited?(source, module) do
    {:ok, source.audited?(module)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp not_a_resource(name) do
    [
      field: :match_resource,
      message:
        "#{name} is not a loadable Ash resource. A subscription matches on the " <>
          "resource name the event log records, so a name nothing writes under " <>
          "would never fire"
    ]
  end
end

defmodule AshBpmn.Resources.Subscription.NotCyclic do
  @moduledoc """
  Publish-time cycle refusal: `match_resource` may not name an `ash_bpmn` or
  `ash_decisions` resource.

  Those domains write rows of their own -- definitions published, decisions
  made -- and if the host audits them, they are event-log entries like any
  other. A subscription matching one would start processes that produce the
  events that start it. Refused at publish time, by name. The alternative was
  to rely on guards happening to be narrow enough, which is "probably
  terminates" dressed as a design.

  `kind: :signal` is the one named exception (TRD §4.5): a signal row *is* an
  event in the host's log ordered with everything else, and signal-mediated
  cycles are bounded by `Dispatch.depth` rather than by this refusal.

  Matched by module prefix rather than an enumerated list, so a resource added
  to either domain later is covered without anyone remembering to come back
  here.
  """

  use Ash.Resource.Validation

  @refused_prefixes ["AshBpmn.", "AshDecisions."]

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :kind) == :signal do
      :ok
    else
      resource =
        changeset
        |> Ash.Changeset.get_attribute(:match_resource)
        |> Kernel.||("")
        |> AshBpmn.Resources.Subscription.ResourceName.short()

      if Enum.any?(@refused_prefixes, &String.starts_with?(resource, &1)) do
        {:error,
         field: :match_resource,
         message:
           "a subscription may not match #{resource}: the ash_bpmn and ash_decisions " <>
             "domains write rows of their own, so a subscription on one would start " <>
             "processes that feed it"}
      else
        :ok
      end
    end
  end
end

defmodule AshBpmn.Resources.Subscription.DecisionExists do
  @moduledoc """
  Publish-time check that a `:decision` route names a decision that exists,
  via the configured `AshBpmn.DecisionResolver`.

  Config-gated exactly like the compiler's `businessRuleTask` check: with no
  resolver configured, the refusal names `config :ash_bpmn,
  decision_resolver`. And a resolver that cannot answer `exists?/1` must not
  silently pass -- publishing an unverifiable reference is the thing this
  check exists to prevent.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :route_kind) do
      :decision ->
        verify(
          AshBpmn.Config.decision_resolver(),
          Ash.Changeset.get_attribute(changeset, :decision_key)
        )

      _ ->
        :ok
    end
  end

  defp verify(_resolver, key) when is_nil(key) or key == "", do: :ok

  defp verify(nil, _key) do
    {:error,
     field: :decision_key,
     message:
       "route_kind :decision needs a decision resolver, but none is configured. " <>
         "Set `config :ash_bpmn, decision_resolver: MyApp.Bpmn.Decisions`."}
  end

  defp verify(resolver, key) do
    case safe_exists?(resolver, key) do
      :ok ->
        :ok

      {:error, :missing} ->
        {:error,
         field: :decision_key, message: "references decision '#{key}', which does not exist"}

      {:error, reason} ->
        {:error,
         field: :decision_key, message: "could not verify decision '#{key}': #{inspect(reason)}"}
    end
  end

  defp safe_exists?(resolver, ref) do
    if resolver.exists?(ref), do: :ok, else: {:error, :missing}
  rescue
    e -> {:error, Exception.message(e)}
  end
end

defmodule AshBpmn.Resources.Subscription.CompileExpressions do
  @moduledoc """
  Stamps the stored compiled form at publish.

  Each expression is stored as **source text** (`AshBpmn.Feel.compile/1`'s
  return), never a parsed tree, so an engine upgrade re-evaluates rather than
  breaks -- and which engine agreed the expressions were valid at publish time
  is stamped alongside, so the upgrade is visible in the row rather than
  silent. `Definition.graph`'s `feel_engine` entry is the pattern.

  Runs after the publish validations, so every compile here has already been
  proven to succeed; a failure is recorded as an action error rather than
  trusted away.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    compiled =
      %{
        "guard" =>
          compile(Ash.Changeset.get_attribute(changeset, :guard_feel), :guard_feel, changeset),
        "subject_of" =>
          compile(Ash.Changeset.get_attribute(changeset, :subject_of), :subject_of, changeset),
        "correlation_key_feel" =>
          compile(
            Ash.Changeset.get_attribute(changeset, :correlation_key_feel),
            :correlation_key_feel,
            changeset
          ),
        "feel_engine" => %{"name" => "boxic_feel", "version" => engine_version()}
      }

    Ash.Changeset.change_attribute(changeset, :compiled, compiled)
  end

  defp compile(nil, _field, _changeset), do: nil

  defp compile(source, field, changeset) do
    case AshBpmn.Feel.compile(source) do
      {:ok, stored} ->
        stored

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: field, message: "could not compile: #{message}")
        nil
    end
  end

  # Mirrors how the compiler stamps its graphs: the OTP app version at the
  # time of the build, or "unknown" when the app cannot be introspected.
  defp engine_version do
    case Application.spec(:boxic_feel, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end

defmodule AshBpmn.Resources.Subscription.FilterLatestPublished do
  @moduledoc false

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    key = Ash.Query.get_argument(query, :key)

    query
    |> Ash.Query.filter(status == :published)
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
  end
end
