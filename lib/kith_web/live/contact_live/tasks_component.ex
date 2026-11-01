defmodule KithWeb.ContactLive.TasksComponent do
  use KithWeb, :live_component

  alias Kith.Tasks

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:tasks, [])
     |> assign(:show_form, false)
     |> assign(:editing_task_id, nil)}
  end

  @impl true
  def update(assigns, socket) do
    tasks = Tasks.list_tasks(assigns.account_id, contact_id: assigns.contact_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:tasks, tasks)
     |> assign_new(:changeset, fn -> Tasks.Task.changeset(%Tasks.Task{}, %{}) end)}
  end

  @impl true
  def handle_event("show-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_task_id, nil)
     |> assign(:changeset, Tasks.Task.changeset(%Tasks.Task{}, %{}))}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_task_id, nil)}
  end

  def handle_event("save-task", %{"task" => task_params}, socket) do
    params = Map.put(task_params, "contact_id", socket.assigns.contact_id)

    case Tasks.create_task(socket.assigns.account_id, socket.assigns.current_user_id, params) do
      {:ok, _task} ->
        tasks = Tasks.list_tasks(socket.assigns.account_id, contact_id: socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:tasks, tasks)
         |> assign(:show_form, false)
         |> put_flash(:info, "Task added.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("edit-task", %{"id" => id}, socket) do
    task = Tasks.get_task!(socket.assigns.account_id, String.to_integer(id))
    changeset = Tasks.Task.changeset(task, %{})

    {:noreply,
     socket
     |> assign(:editing_task_id, task.id)
     |> assign(:show_form, false)
     |> assign(:changeset, changeset)}
  end

  def handle_event("update-task", %{"task" => task_params}, socket) do
    task = Tasks.get_task!(socket.assigns.account_id, socket.assigns.editing_task_id)

    case Tasks.update_task(task, task_params) do
      {:ok, _task} ->
        tasks = Tasks.list_tasks(socket.assigns.account_id, contact_id: socket.assigns.contact_id)

        {:noreply,
         socket
         |> assign(:tasks, tasks)
         |> assign(:editing_task_id, nil)
         |> put_flash(:info, "Task updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("complete-task", %{"id" => id}, socket) do
    task = Tasks.get_task!(socket.assigns.account_id, String.to_integer(id))
    {:ok, _} = Tasks.complete_task(task)
    tasks = Tasks.list_tasks(socket.assigns.account_id, contact_id: socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:tasks, tasks)
     |> put_flash(:info, "Task completed.")}
  end

  def handle_event("delete-task", %{"id" => id}, socket) do
    task = Tasks.get_task!(socket.assigns.account_id, String.to_integer(id))
    {:ok, _} = Tasks.delete_task(task)
    tasks = Tasks.list_tasks(socket.assigns.account_id, contact_id: socket.assigns.contact_id)

    {:noreply,
     socket
     |> assign(:tasks, tasks)
     |> put_flash(:info, "Task deleted.")}
  end

  defp priority_badge_class("high"),
    do: "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"

  defp priority_badge_class("medium"),
    do: "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400"

  defp priority_badge_class("low"),
    do: "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400"

  defp priority_badge_class(_),
    do: "bg-gray-100 text-gray-700 dark:bg-gray-900/30 dark:text-gray-400"

  defp overdue?(%{due_date: nil}), do: false

  defp overdue?(%{due_date: _due_date, status: status}) when status in ["completed", "cancelled"],
    do: false

  defp overdue?(%{due_date: due_date}), do: Date.compare(due_date, Date.utc_today()) == :lt

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-semibold">Tasks</h2>
        <%= if @can_edit do %>
          <button
            id={"add-task-#{@contact_id}"}
            phx-click="show-form"
            phx-target={@myself}
            class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
          >
            <.icon name="hero-plus" class="size-4" /> Add Task
          </button>
        <% end %>
      </div>

      <%!-- Add task form --%>
      <%= if @show_form do %>
        <div class="rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-sm mb-4">
          <div class="p-4">
            <.form for={%{}} phx-submit="save-task" phx-target={@myself}>
              <div class="space-y-3">
                <div>
                  <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                    Title *
                  </label>
                  <input
                    type="text"
                    name="task[title]"
                    required
                    class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                    Description
                  </label>
                  <textarea
                    name="task[description]"
                    rows="2"
                    class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                  ></textarea>
                </div>
                <div class="grid grid-cols-2 gap-3">
                  <div>
                    <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                      Due Date
                    </label>
                    <input
                      type="date"
                      name="task[due_date]"
                      class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                    />
                  </div>
                  <div>
                    <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                      Priority
                    </label>
                    <select
                      name="task[priority]"
                      class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                    >
                      <option value="low">Low</option>
                      <option value="medium" selected>Medium</option>
                      <option value="high">High</option>
                    </select>
                  </div>
                </div>
              </div>
              <div class="flex gap-2 mt-3">
                <button
                  type="submit"
                  class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
                >
                  Save
                </button>
                <button
                  type="button"
                  phx-click="cancel-form"
                  phx-target={@myself}
                  class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-2.5 py-1.5 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>

      <%!-- Tasks list --%>
      <%= if @tasks == [] and not @show_form do %>
        <KithUI.empty_state
          size={:compact}
          icon="hero-clipboard-document-check"
          title="No tasks yet"
          message="Track things you need to do for this contact."
        >
          <:actions :if={@can_edit}>
            <button
              phx-click="show-form"
              phx-target={@myself}
              class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
            >
              Add Task
            </button>
          </:actions>
        </KithUI.empty_state>
      <% end %>

      <div class="space-y-3">
        <%= for task <- @tasks do %>
          <div class={[
            "rounded-[var(--radius-lg)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] shadow-sm",
            task.status == "completed" && "opacity-60"
          ]}>
            <div class="p-4">
              <%= if @editing_task_id == task.id do %>
                <%!-- Inline edit form --%>
                <.form for={%{}} phx-submit="update-task" phx-target={@myself}>
                  <div class="space-y-3">
                    <div>
                      <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                        Title *
                      </label>
                      <input
                        type="text"
                        name="task[title]"
                        value={task.title}
                        required
                        class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                      />
                    </div>
                    <div>
                      <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                        Description
                      </label>
                      <textarea
                        name="task[description]"
                        rows="2"
                        class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                      >{task.description}</textarea>
                    </div>
                    <div class="grid grid-cols-2 gap-3">
                      <div>
                        <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                          Due Date
                        </label>
                        <input
                          type="date"
                          name="task[due_date]"
                          value={task.due_date && Date.to_iso8601(task.due_date)}
                          class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                        />
                      </div>
                      <div>
                        <label class="block text-sm font-medium text-[var(--color-text-primary)] mb-1">
                          Priority
                        </label>
                        <select
                          name="task[priority]"
                          class="w-full rounded-[var(--radius-md)] border border-[var(--color-border)] bg-[var(--color-surface-elevated)] px-3 py-2 text-sm text-[var(--color-text-primary)] focus:border-[var(--color-border-focus)] focus:outline-none focus:ring-2 focus:ring-[var(--color-border-focus)]/20"
                        >
                          <option value="low" selected={task.priority == "low"}>Low</option>
                          <option value="medium" selected={task.priority == "medium"}>Medium</option>
                          <option value="high" selected={task.priority == "high"}>High</option>
                        </select>
                      </div>
                    </div>
                  </div>
                  <div class="flex gap-2 mt-3">
                    <button
                      type="submit"
                      class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] bg-[var(--color-accent)] text-[var(--color-accent-foreground)] px-3 py-1.5 text-xs font-medium hover:bg-[var(--color-accent-hover)] transition-colors cursor-pointer"
                    >
                      Save
                    </button>
                    <button
                      type="button"
                      phx-click="cancel-form"
                      phx-target={@myself}
                      class="inline-flex items-center gap-1.5 rounded-[var(--radius-md)] px-2.5 py-1.5 text-xs font-medium text-[var(--color-text-secondary)] hover:bg-[var(--color-surface-sunken)] hover:text-[var(--color-text-primary)] transition-colors cursor-pointer"
                    >
                      Cancel
                    </button>
                  </div>
                </.form>
              <% else %>
                <%!-- Task display --%>
                <div class="flex items-start justify-between">
                  <div class="flex items-start gap-3 flex-1">
                    <%= if task.status != "completed" and @can_edit do %>
                      <button
                        phx-click="complete-task"
                        phx-value-id={task.id}
                        phx-target={@myself}
                        class="mt-0.5 rounded-full border-2 border-[var(--color-border)] size-5 hover:border-[var(--color-accent)] transition-colors cursor-pointer flex-shrink-0"
                        title="Mark complete"
                      ></button>
                    <% else %>
                      <.icon
                        name="hero-check-circle-solid"
                        class="size-5 text-[var(--color-success)] mt-0.5 flex-shrink-0"
                      />
                    <% end %>
                    <div class="flex-1 min-w-0">
                      <p class={[
                        "text-sm font-medium text-[var(--color-text-primary)]",
                        task.status == "completed" && "line-through"
                      ]}>
                        {task.title}
                      </p>
                      <p
                        :if={task.description}
                        class="text-xs text-[var(--color-text-tertiary)] mt-0.5 line-clamp-2"
                      >
                        {task.description}
                      </p>
                      <div class="flex items-center gap-2 mt-1">
                        <span
                          :if={task.due_date}
                          class={[
                            "text-xs",
                            overdue?(task) && "text-[var(--color-error)]",
                            !overdue?(task) && "text-[var(--color-text-tertiary)]"
                          ]}
                        >
                          Due <.date_display date={task.due_date} />
                        </span>
                        <span class={[
                          "inline-flex items-center rounded-full px-1.5 py-0.5 text-[10px] font-medium",
                          priority_badge_class(task.priority)
                        ]}>
                          {String.capitalize(task.priority)}
                        </span>
                      </div>
                    </div>
                  </div>
                  <%= if @can_edit do %>
                    <div class="flex items-center gap-1 ms-2 shrink-0">
                      <button
                        :if={task.status != "completed"}
                        phx-click="edit-task"
                        phx-value-id={task.id}
                        phx-target={@myself}
                        class="text-[var(--color-text-tertiary)] hover:text-[var(--color-accent)] transition-colors cursor-pointer"
                        title="Edit"
                      >
                        <.icon name="hero-pencil-square" class="size-4" />
                      </button>
                      <button
                        phx-click="delete-task"
                        phx-value-id={task.id}
                        phx-target={@myself}
                        data-confirm="Delete this task? This cannot be undone."
                        class="text-[var(--color-text-tertiary)] hover:text-[var(--color-error)] transition-colors cursor-pointer"
                        title="Delete"
                      >
                        <.icon name="hero-trash" class="size-4" />
                      </button>
                    </div>
                  <% end %>
                </div>
                <div class="flex items-center justify-between mt-2 text-xs text-[var(--color-text-tertiary)]">
                  <span><.datetime_display datetime={task.inserted_at} /></span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
