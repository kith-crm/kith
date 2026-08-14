defmodule KithWeb.Router do
  use KithWeb, :router

  import KithWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KithWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug KithWeb.Plugs.CSP
    plug :fetch_current_scope_for_user
    plug KithWeb.Plugs.AssignLocale
  end

  # REST API pipeline — JSON only, no CSRF, no session.
  # Versioning strategy: v1 lives at /api (no version prefix in URL).
  # Future breaking changes will use /api/v2 with a new router scope.
  # v1 will remain available during a deprecation period.
  pipeline :api do
    plug :accepts, ["json"]
    plug KithWeb.Plugs.ApiVersionHeader
  end

  # Browser-based JSON API (needs session for challenge storage, but returns JSON)
  pipeline :browser_json do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # Well-known URLs for DAV client auto-discovery (RFC 6764)
  # Uses forward (not get) so PROPFIND and other methods are handled too
  scope "/.well-known" do
    forward "/carddav", Kith.DAV.WellKnownCardDAVPlug
  end

  # CardDAV server — handles PROPFIND, REPORT, GET, PUT, DELETE via plug
  # Auth is handled internally by Kith.DAV.Auth (HTTP Basic over TLS)
  scope "/dav" do
    forward "/", Kith.DAV.CardDAVPlug
  end

  # Health check — no auth required (used by Docker HEALTHCHECK and orchestrators)
  scope "/health", KithWeb do
    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  # Prometheus metrics — Bearer token auth, no user session
  # Caddy should restrict external access; Prometheus scrapes from Docker network.
  pipeline :metrics do
    plug KithWeb.Plugs.MetricsAuth
  end

  scope "/" do
    pipe_through :metrics
    get "/metrics", PromEx.Plug, prom_ex_module: Kith.PromEx
  end

  # Backward-compatible single health endpoint
  scope "/", KithWeb do
    get "/health", HealthController, :index
  end

  scope "/", KithWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/terms", PageController, :tos
  end

  pipeline :api_public_rate_limited do
    plug :accepts, ["json"]
    plug KithWeb.Plugs.RateLimiter, limit: 20, period: 60_000, key_prefix: "api_auth_token"
  end

  # API token creation (public — no bearer token needed, rate-limited)
  scope "/api", KithWeb.API do
    pipe_through [:api_public_rate_limited]

    post "/auth/token", AuthController, :create
  end

  # API scope — Bearer token auth, per-account rate limiting
  scope "/api", KithWeb.API do
    pipe_through [:api, KithWeb.Plugs.FetchApiUser, KithWeb.Plugs.ApiRateLimiter]

    delete "/auth/token", AuthController, :delete_current
    delete "/auth/token/:id", AuthController, :delete

    # Current user profile
    get "/me", MeController, :show
    patch "/me", MeController, :update

    # Account
    get "/account", AccountController, :show
    patch "/account", AccountController, :update

    # Statistics
    get "/statistics", StatisticsController, :index

    # Contacts CRUD
    get "/contacts", ContactController, :index
    post "/contacts", ContactController, :create
    post "/contacts/merge", ContactController, :merge
    get "/contacts/:id", ContactController, :show
    patch "/contacts/:id", ContactController, :update
    put "/contacts/:id", ContactController, :update
    delete "/contacts/:id", ContactController, :delete

    # Contact actions
    post "/contacts/:contact_id/archive", ContactController, :archive
    delete "/contacts/:contact_id/archive", ContactController, :unarchive
    post "/contacts/:contact_id/favorite", ContactController, :favorite
    delete "/contacts/:contact_id/favorite", ContactController, :unfavorite
    post "/contacts/:contact_id/restore", ContactController, :restore

    # Notes (nested under contact for list/create, flat for show/update/delete)
    get "/contacts/:contact_id/notes", NoteController, :index
    post "/contacts/:contact_id/notes", NoteController, :create
    get "/notes/:id", NoteController, :show
    patch "/notes/:id", NoteController, :update
    delete "/notes/:id", NoteController, :delete
    post "/notes/:id/favorite", NoteController, :favorite
    delete "/notes/:id/favorite", NoteController, :unfavorite

    # Life Events
    get "/contacts/:contact_id/life_events", LifeEventController, :index
    post "/contacts/:contact_id/life_events", LifeEventController, :create
    get "/life_events/:id", LifeEventController, :show
    patch "/life_events/:id", LifeEventController, :update
    delete "/life_events/:id", LifeEventController, :delete

    # Activities
    get "/contacts/:contact_id/activities", ActivityController, :index
    post "/activities", ActivityController, :create
    get "/activities/:id", ActivityController, :show
    patch "/activities/:id", ActivityController, :update
    delete "/activities/:id", ActivityController, :delete

    # Calls
    get "/contacts/:contact_id/calls", CallController, :index
    post "/contacts/:contact_id/calls", CallController, :create
    get "/calls/:id", CallController, :show
    patch "/calls/:id", CallController, :update
    delete "/calls/:id", CallController, :delete

    # Relationships
    get "/contacts/:contact_id/relationships", RelationshipController, :index
    post "/contacts/:contact_id/relationships", RelationshipController, :create
    delete "/relationships/:id", RelationshipController, :delete

    # Addresses
    get "/contacts/:contact_id/addresses", AddressController, :index
    post "/contacts/:contact_id/addresses", AddressController, :create
    patch "/addresses/:id", AddressController, :update
    delete "/addresses/:id", AddressController, :delete

    # Contact Fields
    get "/contacts/:contact_id/contact_fields", ContactFieldController, :index
    post "/contacts/:contact_id/contact_fields", ContactFieldController, :create
    patch "/contact_fields/:id", ContactFieldController, :update
    delete "/contact_fields/:id", ContactFieldController, :delete

    # Documents
    get "/contacts/:contact_id/documents", DocumentController, :index
    post "/contacts/:contact_id/documents", DocumentController, :create
    delete "/documents/:id", DocumentController, :delete

    # Photos
    get "/contacts/:contact_id/photos", PhotoController, :index
    post "/contacts/:contact_id/photos", PhotoController, :create
    delete "/photos/:id", PhotoController, :delete

    # Reminders
    get "/reminders/upcoming", ReminderController, :upcoming
    get "/contacts/:contact_id/reminders", ReminderController, :index
    post "/contacts/:contact_id/reminders", ReminderController, :create
    get "/reminders/:id", ReminderController, :show
    patch "/reminders/:id", ReminderController, :update
    delete "/reminders/:id", ReminderController, :delete
    post "/reminder_instances/:id/resolve", ReminderController, :resolve_instance
    post "/reminder_instances/:id/dismiss", ReminderController, :dismiss_instance
    post "/reminder_instances/:id/snooze", ReminderController, :snooze_instance

    # Tasks
    get "/contacts/:contact_id/tasks", TaskController, :index
    post "/contacts/:contact_id/tasks", TaskController, :create
    get "/tasks/:id", TaskController, :show
    patch "/tasks/:id", TaskController, :update
    delete "/tasks/:id", TaskController, :delete
    post "/tasks/:id/complete", TaskController, :complete

    # Pets
    get "/contacts/:contact_id/pets", PetController, :index
    post "/contacts/:contact_id/pets", PetController, :create
    get "/pets/:id", PetController, :show
    patch "/pets/:id", PetController, :update
    delete "/pets/:id", PetController, :delete

    # Gifts
    get "/contacts/:contact_id/gifts", GiftController, :index
    post "/contacts/:contact_id/gifts", GiftController, :create
    get "/gifts/:id", GiftController, :show
    patch "/gifts/:id", GiftController, :update
    delete "/gifts/:id", GiftController, :delete

    # Debts
    get "/contacts/:contact_id/debts", DebtController, :index
    post "/contacts/:contact_id/debts", DebtController, :create
    get "/debts/:id", DebtController, :show
    patch "/debts/:id", DebtController, :update
    delete "/debts/:id", DebtController, :delete
    post "/debts/:id/settle", DebtController, :settle
    post "/debts/:id/write_off", DebtController, :write_off
    post "/debts/:id/payments", DebtController, :add_payment
    delete "/debt_payments/:id", DebtController, :delete_payment

    # Conversations
    get "/contacts/:contact_id/conversations", ConversationController, :index
    post "/contacts/:contact_id/conversations", ConversationController, :create
    get "/conversations/:id", ConversationController, :show
    patch "/conversations/:id", ConversationController, :update
    delete "/conversations/:id", ConversationController, :delete

    # Messages
    get "/conversations/:conversation_id/messages", MessageController, :index
    post "/conversations/:conversation_id/messages", MessageController, :create

    # Journal (account-level, not contact-scoped)
    get "/journal", JournalController, :index
    post "/journal", JournalController, :create
    get "/journal/:id", JournalController, :show
    patch "/journal/:id", JournalController, :update
    delete "/journal/:id", JournalController, :delete

    # Tags
    get "/tags", TagController, :index
    post "/tags", TagController, :create
    patch "/tags/:id", TagController, :update
    delete "/tags/:id", TagController, :delete
    post "/contacts/:contact_id/tags", TagController, :assign
    delete "/contacts/:contact_id/tags/:tag_id", TagController, :remove
    post "/tags/bulk_assign", TagController, :bulk_assign
    post "/tags/bulk_remove", TagController, :bulk_remove

    # Reference Data
    get "/genders", GenderController, :index
    post "/genders", GenderController, :create
    patch "/genders/:id", GenderController, :update
    delete "/genders/:id", GenderController, :delete

    get "/relationship_types", RelationshipTypeController, :index
    post "/relationship_types", RelationshipTypeController, :create
    patch "/relationship_types/:id", RelationshipTypeController, :update
    delete "/relationship_types/:id", RelationshipTypeController, :delete

    get "/contact_field_types", ContactFieldTypeController, :index
    post "/contact_field_types", ContactFieldTypeController, :create
    patch "/contact_field_types/:id", ContactFieldTypeController, :update
    delete "/contact_field_types/:id", ContactFieldTypeController, :delete

    get "/emotions", EmotionController, :index
    post "/emotions", EmotionController, :create
    patch "/emotions/:id", EmotionController, :update
    delete "/emotions/:id", EmotionController, :delete

    get "/activity_type_categories", ActivityTypeCategoryController, :index
    post "/activity_type_categories", ActivityTypeCategoryController, :create
    patch "/activity_type_categories/:id", ActivityTypeCategoryController, :update
    delete "/activity_type_categories/:id", ActivityTypeCategoryController, :delete

    get "/life_event_types", LifeEventTypeController, :index
    post "/life_event_types", LifeEventTypeController, :create
    patch "/life_event_types/:id", LifeEventTypeController, :update
    delete "/life_event_types/:id", LifeEventTypeController, :delete

    # Export endpoints
    get "/contacts/export.vcf", ContactExportController, :bulk
    get "/contacts/:id/export.vcf", ContactExportController, :show
    get "/export", ExportController, :create

    # Import endpoint
    post "/contacts/import", ContactImportController, :create

    # Duplicate Detection
    get "/duplicates", DuplicateController, :index
    post "/duplicates/scan", DuplicateController, :scan
    post "/duplicates/:id/dismiss", DuplicateController, :dismiss

    # Mobile push integration point — implement in v2
    post "/devices", DeviceController, :create
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:kith, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: KithWeb.Telemetry
    end
  end

  ## Authentication routes

  # Authenticated routes that do NOT require confirmed email
  scope "/", KithWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated_unconfirmed,
      on_mount: [{KithWeb.UserAuth, :require_authenticated}] do
      live "/users/confirm-email", UserLive.ConfirmEmailPending, :new
    end
  end

  # Authenticated file serving (local storage backend)
  scope "/", KithWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/uploads/*path", UploadsController, :show
  end

  # Authenticated routes — require logged-in + confirmed user
  scope "/", KithWeb do
    pipe_through [:browser, :require_authenticated_user, :require_confirmed_user]

    live_session :require_authenticated_user,
      on_mount: [{KithWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/users/totp-setup", UserLive.TotpSetup, :new

      # Dashboard
      live "/dashboard", DashboardLive.Index, :index

      # Reminders
      live "/reminders/upcoming", ReminderLive.Upcoming, :index

      # Journal
      live "/journal", JournalLive.Index, :index

      # Contact management
      live "/contacts", ContactLive.Index, :index
      live "/contacts/archived", ContactLive.Index, :archived
      live "/contacts/trash", ContactLive.Index, :trash
      live "/contacts/duplicates", ContactLive.Index, :duplicates
      live "/contacts/new", ContactLive.New, :new
      live "/contacts/:id", ContactLive.Show, :show
      live "/contacts/:id/edit", ContactLive.Edit, :edit
      live "/contacts/:id/merge", ContactLive.Merge, :index

      # Settings
      live "/settings/tags", SettingsLive.Tags, :index
      live "/settings/emotions", SettingsLive.Emotions, :index
      live "/settings/activity-types", SettingsLive.ActivityTypes, :index
      live "/settings/life-event-types", SettingsLive.LifeEventTypes, :index
      live "/settings/integrations", SettingsLive.Integrations, :index
      live "/settings/account", SettingsLive.Account, :index
      live "/settings/import", ImportWizardLive, :index
      live "/settings/imports", ImportHistoryLive.Index, :index
      live "/settings/imports/:id", ImportHistoryLive.Show, :show
      live "/settings/export", SettingsLive.Export, :index

      # Immich review
      live "/contacts/:id/immich-review", ContactLive.ImmichReview, :index

      # Admin pages
      live "/settings/audit-log", SettingsLive.AuditLog, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  # Admin-only Oban Web dashboard.
  # The oban_dashboard macro defines its own internal live_session, so it must
  # be placed outside any other live_session block.
  scope "/admin" do
    pipe_through [:browser, :require_authenticated_user, :require_confirmed_user]

    import Oban.Web.Router

    oban_dashboard("/oban",
      on_mount: [{KithWeb.UserAuth, :require_admin}],
      csp_nonce_assign_key: :csp_nonce
    )
  end

  # WebAuthn registration (authenticated, JSON over session)
  scope "/auth/webauthn", KithWeb do
    pipe_through [:browser_json, :require_authenticated_user]

    post "/register/challenge", WebauthnController, :register_challenge
    post "/register/complete", WebauthnController, :register_complete
    get "/credentials", WebauthnController, :list_credentials
    delete "/credentials/:id", WebauthnController, :delete_credential
  end

  # WebAuthn authentication (public, JSON over session)
  scope "/auth/webauthn", KithWeb do
    pipe_through [:browser_json]

    post "/authenticate/challenge", WebauthnController, :authenticate_challenge
    post "/authenticate/complete", WebauthnController, :authenticate_complete
  end

  # OAuth routes (browser-based, public)
  scope "/auth", KithWeb do
    pipe_through [:browser]

    get "/:provider", OAuthController, :request
    get "/:provider/callback", OAuthController, :callback
  end

  # Public auth routes — may or may not be logged in
  scope "/", KithWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{KithWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/confirm/:token", UserLive.Confirmation, :new
      live "/users/reset-password", UserLive.ForgotPassword, :new
      live "/users/reset-password/:token", UserLive.ResetPassword, :new
      live "/users/two-factor", UserLive.TotpChallenge, :new

      # Team invitation acceptance (unauthenticated)
      live "/invitations/:token", UserLive.InvitationAcceptance, :new
    end

    post "/users/log-in", UserSessionController, :create
    post "/users/totp-verify", UserSessionController, :totp_verify
    delete "/users/log-out", UserSessionController, :delete
  end
end
