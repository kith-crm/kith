defmodule Kith.Policy do
  @moduledoc """
  Authorization policy for Kith.

  Roles:
    - `admin`  — full access: account settings, user management, all CRUD
    - `editor` — CRUD on contacts and content, no account settings or user management
    - `viewer` — read-only access to contacts and content

  Usage:

      Kith.Policy.can?(user, :create, :contact)
      Kith.Policy.can?(user, :update, :account)

  Returns `true` or `false`. Raises no exceptions — callers decide how to
  handle unauthorized access (redirect, 403, flash message, etc.).
  """

  alias Kith.Accounts.User

  @type action :: :create | :read | :update | :delete | :manage
  @type resource ::
          :account
          | :user
          | :invitation
          | :contact
          | :note
          | :document
          | :photo
          | :address
          | :contact_field
          | :relationship
          | :tag
          | :life_event
          | :activity
          | :call
          | :reminder
          | :audit_log
          | :export
          | :import
          | :task
          | :pet
          | :gift
          | :debt
          | :conversation
          | :journal
          | :duplicate_candidate
          | :reference_data
          | :oban

  @doc """
  Returns true if the user is authorized to perform the given action on the resource.
  """
  @spec can?(User.t(), action(), resource()) :: boolean()
  def can?(%User{role: role}, action, resource) do
    authorized?(role, action, resource)
  end

  # ── Admin: full access ───────────────────────────────────────────────
  defp authorized?("admin", _action, _resource), do: true

  # ── Admin-only resources: deny for editor/viewer ─────────────────────
  defp authorized?(role, _action, :oban) when role in ["editor", "viewer"], do: false

  # ── Editor: CRUD on contacts and content, no account/user management ─
  defp authorized?("editor", :read, resource) when resource in [:account, :audit_log], do: true

  defp authorized?("editor", _action, resource) when resource in [:account, :user, :invitation],
    do: false

  defp authorized?("editor", _action, _resource), do: true

  # ── Viewer: read-only ────────────────────────────────────────────────
  defp authorized?("viewer", :read, _resource), do: true
  defp authorized?("viewer", _action, _resource), do: false

  # ── Unknown role: deny ───────────────────────────────────────────────
  defp authorized?(_role, _action, _resource), do: false

  @doc """
  Raises if the user is not authorized. Useful in controller/LiveView pipelines.
  """
  @spec authorize!(User.t(), action(), resource()) :: :ok
  def authorize!(%User{} = user, action, resource) do
    if can?(user, action, resource) do
      :ok
    else
      raise Kith.NotAuthorizedError, %{user: user, action: action, resource: resource}
    end
  end
end

defmodule Kith.NotAuthorizedError do
  @moduledoc "Raised when a user attempts an unauthorized action."
  defexception [:message, :user, :action, :resource]

  @impl true
  def exception(%{user: user, action: action, resource: resource}) do
    %__MODULE__{
      message: "User #{user.id} (#{user.role}) is not authorized to #{action} #{resource}",
      user: user,
      action: action,
      resource: resource
    }
  end
end

defimpl Plug.Exception, for: Kith.NotAuthorizedError do
  def status(_exception), do: 403
  def actions(_exception), do: []
end
