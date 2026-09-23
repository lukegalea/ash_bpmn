# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Web.TaskListLive do
  @moduledoc """
  BPMN human task list LiveView.

  Provides a `use` macro that injects a complete LiveView listing open and
  claimed tasks for a set of principal IDs.

  ## Usage

      # With a dynamic resolver:
      defmodule MyAppWeb.Bpmn.TaskListLive do
        use AshBpmn.Web.TaskListLive,
          domain: MyApp.Bpmn,
          principal_ids: {MyAppWeb.Bpmn.Helpers, :current_principal_ids, []}
      end

      # With a literal list (handy for tests):
      defmodule MyAppWeb.Bpmn.TaskListLive do
        use AshBpmn.Web.TaskListLive,
          domain: MyApp.Bpmn,
          principal_ids: ["user-uuid-1", "user-uuid-2"]
      end

  ## Options

    * `:domain` — **required**. The host Ash domain with BPMN resources.
    * `:principal_ids` — **required**. Either a list of principal ID strings,
      or a `{module, function, args}` tuple called as `module.function(args ++ [socket])`.
    * `:task_actions` — optional. Module implementing `AshBpmn.Web.TaskActions`.
      Defaults to `AshBpmn.Web.DefaultTaskActions`.
  """

  # Module-level render shares this import so `~H` is available in
  # `__render__/1` (same shape as DesignerLive/ViewerLive).
  import Phoenix.Component

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    principal_ids = Keyword.fetch!(opts, :principal_ids)
    task_actions_mod = Keyword.get(opts, :task_actions, AshBpmn.Web.DefaultTaskActions)

    quote do
      use Phoenix.LiveView

      import Phoenix.LiveView.Helpers

      @ash_bpmn_tasklist_domain unquote(domain)
      # NOT `Macro.escape/1`. The option arrives as AST -- `{{:__aliases__, _, [...]}, :fun,
      # []}` -- and escaping it stores the AST *of that AST*, so the module reaches
      # `apply/3` as an unexpanded alias tuple rather than an atom. Unquoting injects the AST
      # where it is evaluated, which resolves the alias against the using module's context.
      #
      # The failure is `ArgumentError: 2nd argument: not an atom`, from `:erlang.apply/3`,
      # with nothing pointing at the option that caused it.
      @ash_bpmn_tasklist_principal_ids unquote(principal_ids)
      @ash_bpmn_tasklist_actions_mod unquote(task_actions_mod)

      @impl true
      def mount(_params, _session, socket) do
        {:ok,
         socket
         |> assign(
           open_tasks: [],
           claimed_tasks: [],
           principal_ids: resolve_principal_ids(socket)
         )}
      end

      @impl true
      def handle_params(_params, _uri, socket) do
        socket = load_tasks(socket)
        {:noreply, socket}
      end

      # ── Claim ───────────────────────────────────────────────────────────

      @impl true
      def handle_event("claim", %{"id" => task_id}, socket) do
        principal_ids = socket.assigns.principal_ids
        principal_id = List.first(principal_ids) || ""

        result =
          @ash_bpmn_tasklist_actions_mod.claim(
            task_id,
            %{type: :user, id: principal_id},
            domain: @ash_bpmn_tasklist_domain
          )

        socket =
          case result do
            {:ok, _task} ->
              socket
              |> put_flash(:info, "Task claimed")
              |> load_tasks()

            {:error, error} ->
              put_flash(socket, :error, inspect(error))
          end

        {:noreply, socket}
      end

      # ── Complete ────────────────────────────────────────────────────────

      @impl true
      def handle_event(
            "complete",
            %{
              "task_id" => task_id,
              "outcome" => outcome,
              "comment" => comment
            },
            socket
          ) do
        # The outcome is the text the form submitted. It is cast and validated
        # by the `complete` action against a `:string` attribute -- never made
        # into an atom here. The field is free text on the wire, and
        # `String.to_atom/1` on it is an unbounded atom table fed by anyone who
        # can open the task list. A blank field keeps the historical default.
        outcome =
          if is_binary(outcome) and outcome != "", do: outcome, else: "completed"

        result =
          @ash_bpmn_tasklist_actions_mod.complete(
            task_id,
            outcome,
            comment,
            domain: @ash_bpmn_tasklist_domain
          )

        socket =
          case result do
            {:ok, _task} ->
              socket
              |> put_flash(:info, "Task completed")
              |> load_tasks()

            {:error, error} ->
              put_flash(socket, :error, inspect(error))
          end

        {:noreply, socket}
      end

      # ── Delegate ────────────────────────────────────────────────────────

      @impl true
      def handle_event(
            "delegate",
            %{
              "task_id" => task_id,
              "principal_id" => principal_id
            },
            socket
          ) do
        result =
          @ash_bpmn_tasklist_actions_mod.delegate(
            task_id,
            principal_id,
            domain: @ash_bpmn_tasklist_domain
          )

        socket =
          case result do
            {:ok, _task} ->
              socket
              |> put_flash(:info, "Task delegated")
              |> load_tasks()

            {:error, error} ->
              put_flash(socket, :error, inspect(error))
          end

        {:noreply, socket}
      end

      @impl true
      def render(assigns) do
        AshBpmn.Web.TaskListLive.__render__(assigns)
      end

      # ── Private helpers ─────────────────────────────────────────────────

      # Delegated rather than case-matched here: the option is a compile-time
      # constant in the generated module, so an inline `case` leaves one clause
      # provably dead and dialyzer rightly complains about it.
      defp resolve_principal_ids(socket) do
        AshBpmn.Web.TaskListLive.resolve_principal_ids(
          @ash_bpmn_tasklist_principal_ids,
          socket
        )
      end

      defp load_tasks(socket) do
        {:ok, %{human_task: human_task_mod, task_candidate: task_candidate_mod}} =
          AshBpmn.Resources.for_domain(@ash_bpmn_tasklist_domain)

        principal_ids = socket.assigns.principal_ids
        opts = AshBpmn.Scope.engine(AshBpmn.Scope.from_assigns(socket.assigns))

        all_tasks =
          human_task_mod
          |> Ash.Query.for_read(:read)
          |> Ash.Query.do_filter(status: [in: [:open, :claimed]])
          |> Ash.read!(opts)

        task_ids = Enum.map(all_tasks, & &1.id)

        candidates =
          if task_ids != [] do
            task_candidate_mod
            |> Ash.Query.for_read(:read)
            |> Ash.Query.do_filter(task_id: [in: task_ids])
            |> Ash.read!(opts)
          else
            []
          end

        candidates_by_task =
          Enum.group_by(candidates, & &1.task_id)

        principal_id_set = MapSet.new(principal_ids)

        matching_tasks =
          Enum.filter(all_tasks, fn task ->
            task_candidates = Map.get(candidates_by_task, task.id, [])

            Enum.any?(task_candidates, fn c ->
              MapSet.member?(principal_id_set, c.principal_id)
            end)
          end)

        open_tasks = Enum.filter(matching_tasks, &(&1.status == :open))
        claimed_tasks = Enum.filter(matching_tasks, &(&1.status == :claimed))

        socket
        |> assign(:open_tasks, open_tasks)
        |> assign(:claimed_tasks, claimed_tasks)
      end
    end
  end

  @doc """
  Resolves the `:principal_ids` option into the ids to query tasks for.

  Accepts either a literal list or a `{module, function, args}` tuple, which is
  called with the socket appended to `args`.
  """
  @spec resolve_principal_ids(
          [String.t()] | {module(), atom(), list()},
          Phoenix.LiveView.Socket.t()
        ) ::
          [String.t()]
  def resolve_principal_ids(ids, _socket) when is_list(ids), do: ids

  def resolve_principal_ids({module, function, args}, socket) do
    apply(module, function, args ++ [socket])
  end

  @doc false
  def __render__(assigns) do
    ~H"""
    <div id="ash-bpmn-tasklist" class="ash-bpmn-page">
      <h2 class="ash-bpmn-heading ash-bpmn-heading--lg">
        My Tasks
      </h2>

      <%!-- Open tasks --%>
      <div class="ash-bpmn-section">
        <h3 class="ash-bpmn-overline">
          Open ({length(assigns.open_tasks)})
        </h3>
        <%= for task <- assigns.open_tasks do %>
          <div id={"task-#{task.id}"} class="ash-bpmn-card">
            <div class="ash-bpmn-spread">
              <div class="ash-bpmn-row">
                <span class="ash-bpmn-card__title">
                  {task.name}
                </span>
                <span class="ash-bpmn-subtle">
                  {task.node_id}
                </span>
              </div>
              <button
                type="button"
                phx-click="claim"
                phx-value-id={task.id}
                class="ash-bpmn-btn ash-bpmn-btn--primary"
              >
                Claim
              </button>
            </div>
          </div>
        <% end %>
        <%= if assigns.open_tasks == [] do %>
          <p class="ash-bpmn-subtle">No open tasks.</p>
        <% end %>
      </div>

      <%!-- Claimed tasks --%>
      <div class="ash-bpmn-section">
        <h3 class="ash-bpmn-overline">
          Claimed ({length(assigns.claimed_tasks)})
        </h3>
        <%= for task <- assigns.claimed_tasks do %>
          <div id={"task-#{task.id}"} class="ash-bpmn-card">
            <div class="ash-bpmn-card__title">
              {task.name}
              <span class="ash-bpmn-subtle">
                {task.node_id}
              </span>
            </div>

            <%!-- Complete form --%>
            <form phx-submit="complete" class="ash-bpmn-form-row">
              <input type="hidden" name="task_id" value={task.id} />
              <input
                type="text"
                name="outcome"
                placeholder="Outcome"
                class="ash-bpmn-input ash-bpmn-input--sm"
              />
              <input
                type="text"
                name="comment"
                placeholder="Comment"
                class="ash-bpmn-input"
              />
              <button
                type="submit"
                class="ash-bpmn-btn ash-bpmn-btn--primary"
              >
                Complete
              </button>
            </form>

            <%!-- Delegate form --%>
            <form phx-submit="delegate" class="ash-bpmn-form-row">
              <input type="hidden" name="task_id" value={task.id} />
              <input
                type="text"
                name="principal_id"
                placeholder="Delegate to principal ID"
                class="ash-bpmn-input"
              />
              <button
                type="submit"
                class="ash-bpmn-btn"
              >
                Delegate
              </button>
            </form>
          </div>
        <% end %>
        <%= if assigns.claimed_tasks == [] do %>
          <p class="ash-bpmn-subtle">No claimed tasks.</p>
        <% end %>
      </div>
    </div>
    """
  end
end
