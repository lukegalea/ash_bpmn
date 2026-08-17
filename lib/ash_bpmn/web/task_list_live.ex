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
      @ash_bpmn_tasklist_principal_ids unquote(Macro.escape(principal_ids))
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
        outcome_atom =
          if is_binary(outcome) and outcome != "" do
            String.to_atom(outcome)
          else
            :completed
          end

        result =
          @ash_bpmn_tasklist_actions_mod.complete(
            task_id,
            outcome_atom,
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
        opts = [authorize?: false]

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
    <div id="ash-bpmn-tasklist" class="p-4 bg-white dark:bg-zinc-900">
      <h2 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100 mb-4">
        My Tasks
      </h2>

      <%!-- Open tasks --%>
      <div class="mb-6">
        <h3 class="text-sm font-medium text-zinc-500 dark:text-zinc-400 uppercase tracking-wide mb-2">
          Open ({length(assigns.open_tasks)})
        </h3>
        <%= for task <- assigns.open_tasks do %>
          <div id={"task-#{task.id}"} class="mb-3 p-3 border border-zinc-200 dark:border-zinc-700 rounded-lg">
            <div class="flex items-center justify-between">
              <div>
                <span class="text-sm font-medium text-zinc-900 dark:text-zinc-100">
                  {task.name}
                </span>
                <span class="ml-2 text-xs text-zinc-500 dark:text-zinc-400">
                  {task.node_id}
                </span>
              </div>
              <button
                type="button"
                phx-click="claim"
                phx-value-id={task.id}
                class="px-3 py-1 text-xs font-medium text-white bg-emerald-600 rounded-md hover:bg-emerald-700 transition-colors"
              >
                Claim
              </button>
            </div>
          </div>
        <% end %>
        <%= if assigns.open_tasks == [] do %>
          <p class="text-sm text-zinc-400 dark:text-zinc-500">No open tasks.</p>
        <% end %>
      </div>

      <%!-- Claimed tasks --%>
      <div class="mb-6">
        <h3 class="text-sm font-medium text-zinc-500 dark:text-zinc-400 uppercase tracking-wide mb-2">
          Claimed ({length(assigns.claimed_tasks)})
        </h3>
        <%= for task <- assigns.claimed_tasks do %>
          <div id={"task-#{task.id}"} class="mb-3 p-3 border border-zinc-200 dark:border-zinc-700 rounded-lg">
            <div class="text-sm font-medium text-zinc-900 dark:text-zinc-100 mb-2">
              {task.name}
              <span class="ml-2 text-xs text-zinc-500 dark:text-zinc-400">
                {task.node_id}
              </span>
            </div>

            <%!-- Complete form --%>
            <form phx-submit="complete" class="flex items-center gap-2 mb-2">
              <input type="hidden" name="task_id" value={task.id} />
              <input
                type="text"
                name="outcome"
                placeholder="Outcome"
                class="px-2 py-1 text-xs border border-zinc-300 dark:border-zinc-600 rounded-md bg-white dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100 w-32"
              />
              <input
                type="text"
                name="comment"
                placeholder="Comment"
                class="px-2 py-1 text-xs border border-zinc-300 dark:border-zinc-600 rounded-md bg-white dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100 flex-1"
              />
              <button
                type="submit"
                class="px-3 py-1 text-xs font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700 transition-colors"
              >
                Complete
              </button>
            </form>

            <%!-- Delegate form --%>
            <form phx-submit="delegate" class="flex items-center gap-2">
              <input type="hidden" name="task_id" value={task.id} />
              <input
                type="text"
                name="principal_id"
                placeholder="Delegate to principal ID"
                class="px-2 py-1 text-xs border border-zinc-300 dark:border-zinc-600 rounded-md bg-white dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100 flex-1"
              />
              <button
                type="submit"
                class="px-3 py-1 text-xs font-medium text-zinc-700 dark:text-zinc-300 bg-white dark:bg-zinc-800 border border-zinc-300 dark:border-zinc-600 rounded-md hover:bg-zinc-50 dark:hover:bg-zinc-700 transition-colors"
              >
                Delegate
              </button>
            </form>
          </div>
        <% end %>
        <%= if assigns.claimed_tasks == [] do %>
          <p class="text-sm text-zinc-400 dark:text-zinc-500">No claimed tasks.</p>
        <% end %>
      </div>
    </div>
    """
  end
end
