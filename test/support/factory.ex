defmodule Kith.Factory do
  @moduledoc """
  ExMachina factory for all Kith schemas.

  Every tenant-scoped factory includes `account_id`. If not provided,
  a new account is lazily created via `build(:account)`.

  ## Usage

      import Kith.Factory

      account = insert(:account)
      user = insert(:user, account: account)
      contact = insert(:contact, account: account)
      note = insert(:note, contact: contact, account: account, author: user)

  ## Convenience

      {account, user} = setup_account()
      {account, user} = setup_account(role: "viewer")
  """

  use ExMachina.Ecto, repo: Kith.Repo

  alias Kith.Accounts.{Account, User, AccountInvitation}
  alias Kith.Contacts.{Contact, Note, Tag, Address, ContactField, ContactFieldType, Pet}
  alias Kith.Contacts.{Relationship, RelationshipType, Gender, Emotion, Photo, Document}
  alias Kith.Contacts.{Gift, Debt, DebtPayment}

  alias Kith.Contacts.{
    ImmichCandidate,
    Currency,
    LifeEventType,
    ActivityTypeCategory,
    CallDirection
  }

  alias Kith.Activities.{Activity, Call, LifeEvent}
  alias Kith.Reminders.{Reminder, ReminderInstance, ReminderRule}
  alias Kith.AuditLogs.AuditLog

  # ── Account ──────────────────────────────────────────────────────────

  def account_factory do
    %Account{
      name: sequence(:account_name, &"Test Account #{&1}"),
      timezone: "Etc/UTC",
      locale: "en",
      send_hour: 9,
      feature_flags: %{},
      immich_enabled: false,
      immich_status: "disabled",
      immich_consecutive_failures: 0
    }
  end

  # ── User ─────────────────────────────────────────────────────────────

  def user_factory do
    account = build(:account)

    %User{
      account: account,
      email: sequence(:user_email, &"user#{&1}@example.com"),
      hashed_password: Pbkdf2.hash_pwd_salt("hello world!!"),
      role: "admin",
      confirmed_at: DateTime.utc_now(:second),
      display_name: sequence(:user_display_name, &"User #{&1}")
    }
  end

  def admin_factory do
    build(:user, role: "admin")
  end

  def editor_factory do
    build(:user, role: "editor")
  end

  def viewer_factory do
    build(:user, role: "viewer")
  end

  # ── Contact ──────────────────────────────────────────────────────────

  def contact_factory do
    account = build(:account)

    %Contact{
      account: account,
      first_name: sequence(:contact_first_name, &"Jane#{&1}"),
      last_name: sequence(:contact_last_name, &"Doe#{&1}"),
      display_name: sequence(:contact_display, &"Jane#{&1} Doe#{&1}"),
      favorite: false,
      is_archived: false,
      deceased: false,
      deleted_at: nil,
      immich_status: "unlinked"
    }
  end

  def archived_contact_factory do
    build(:contact, is_archived: true)
  end

  def soft_deleted_contact_factory do
    build(:contact, deleted_at: DateTime.utc_now(:second))
  end

  def deceased_contact_factory do
    build(:contact, deceased: true, deceased_at: Date.utc_today())
  end

  def favorite_contact_factory do
    build(:contact, favorite: true)
  end

  # ── Note ─────────────────────────────────────────────────────────────

  def note_factory do
    contact = build(:contact)

    %Note{
      contact: contact,
      account: contact.account,
      author: build(:user, account: contact.account),
      body: sequence(:note_body, &"<p>Test note #{&1}</p>"),
      favorite: false,
      is_private: false
    }
  end

  # ── Activity ─────────────────────────────────────────────────────────

  def activity_factory do
    account = build(:account)

    %Activity{
      account: account,
      title: sequence(:activity_title, &"Activity #{&1}"),
      description: "Test activity description",
      occurred_at: DateTime.utc_now(:second)
    }
  end

  # ── Call ──────────────────────────────────────────────────────────────

  def call_factory do
    contact = build(:contact)

    %Call{
      contact: contact,
      account: contact.account,
      occurred_at: DateTime.utc_now(:second),
      duration_mins: 15,
      notes: "Test call notes"
    }
  end

  # ── Task ────────────────────────────────────────────────────────────

  def task_factory do
    contact = build(:contact)

    %Kith.Tasks.Task{
      account: contact.account,
      contact: contact,
      creator: build(:user, account: contact.account),
      title: sequence(:task_title, &"Task #{&1}"),
      description: "Test task description",
      due_date: Date.add(Date.utc_today(), 7),
      priority: "medium",
      status: "pending",
      is_private: true
    }
  end

  def completed_task_factory do
    build(:task, status: "completed", completed_at: DateTime.utc_now(:second))
  end

  # ── Pet ────────────────────────────────────────────────────────────

  def pet_factory do
    contact = build(:contact)

    %Pet{
      account: contact.account,
      contact: contact,
      name: sequence(:pet_name, &"Buddy #{&1}"),
      species: "dog",
      breed: "Golden Retriever",
      is_private: true
    }
  end

  # ── LifeEvent ────────────────────────────────────────────────────────

  def life_event_factory do
    contact = build(:contact)

    %LifeEvent{
      contact: contact,
      account: contact.account,
      life_event_type: build(:life_event_type),
      occurred_on: Date.utc_today(),
      note: "Test life event"
    }
  end

  # ── Reminder ─────────────────────────────────────────────────────────

  def reminder_factory do
    contact = build(:contact)
    creator = build(:user, account: contact.account)

    %Reminder{
      contact: contact,
      account: contact.account,
      creator: creator,
      type: "one_time",
      title: sequence(:reminder_title, &"Reminder #{&1}"),
      anchor_date: Date.add(Date.utc_today(), 7),
      next_reminder_date: Date.add(Date.utc_today(), 7),
      interval_unit: nil,
      interval_count: nil,
      active: true
    }
  end

  def birthday_reminder_factory do
    build(:reminder,
      type: "birthday",
      title: nil,
      interval_unit: "year",
      interval_count: 1,
      anchor_date: Date.add(Date.utc_today(), 30),
      next_reminder_date: Date.add(Date.utc_today(), 30)
    )
  end

  def stay_in_touch_reminder_factory do
    build(:reminder,
      type: "stay_in_touch",
      title: nil,
      interval_unit: "month",
      interval_count: 1,
      anchor_date: Date.add(Date.utc_today(), 30),
      next_reminder_date: Date.add(Date.utc_today(), 30)
    )
  end

  def recurring_reminder_factory do
    build(:reminder,
      type: "recurring",
      title: "Weekly check-in",
      interval_unit: "week",
      interval_count: 1,
      anchor_date: Date.add(Date.utc_today(), 7),
      next_reminder_date: Date.add(Date.utc_today(), 7)
    )
  end

  # ── ReminderInstance ─────────────────────────────────────────────────

  def reminder_instance_factory do
    reminder = build(:reminder)

    %ReminderInstance{
      reminder: reminder,
      account: reminder.account,
      contact: reminder.contact,
      status: "pending",
      scheduled_for: DateTime.utc_now(:second),
      fired_at: nil,
      resolved_at: nil,
      occurrence_date: Date.utc_today(),
      kind: "on_day",
      days_before: 0
    }
  end

  # ── ReminderRule ─────────────────────────────────────────────────────

  def reminder_rule_factory do
    %ReminderRule{
      account: build(:account),
      days_before: sequence(:days_before, [0, 7, 30]),
      active: true
    }
  end

  # ── Tag ──────────────────────────────────────────────────────────────

  def tag_factory do
    %Tag{
      account: build(:account),
      name: sequence(:tag_name, &"tag-#{&1}"),
      color: "#3B82F6"
    }
  end

  # ── Relationship ─────────────────────────────────────────────────────

  def relationship_factory do
    account = build(:account)

    %Relationship{
      account: account,
      contact: build(:contact, account: account),
      related_contact: build(:contact, account: account),
      relationship_type: build(:relationship_type)
    }
  end

  # ── RelationshipType ─────────────────────────────────────────────────

  def relationship_type_factory do
    %RelationshipType{
      name: sequence(:rel_type_name, &"RelType #{&1}"),
      reverse_name: sequence(:rel_type_reverse, &"Reverse RelType #{&1}"),
      is_bidirectional: false,
      position: 0,
      account: nil
    }
  end

  # ── Address ──────────────────────────────────────────────────────────

  def address_factory do
    contact = build(:contact)

    %Address{
      contact: contact,
      account: contact.account,
      label: "Home",
      line1: sequence(:address_line1, &"#{&1} Main Street"),
      city: "Springfield",
      province: "IL",
      postal_code: "62701",
      country: "US"
    }
  end

  # ── ContactField ─────────────────────────────────────────────────────

  def contact_field_factory do
    contact = build(:contact)

    %ContactField{
      contact: contact,
      account: contact.account,
      contact_field_type: build(:contact_field_type),
      value: sequence(:cf_value, &"value#{&1}@example.com"),
      label: "Personal"
    }
  end

  # ── ContactFieldType ─────────────────────────────────────────────────

  def contact_field_type_factory do
    %ContactFieldType{
      name: sequence(:cft_name, &"FieldType #{&1}"),
      protocol: "mailto:",
      icon: "mail",
      vcard_label: "EMAIL",
      position: 0,
      account: nil
    }
  end

  # ── Gender ───────────────────────────────────────────────────────────

  def gender_factory do
    %Gender{
      name: sequence(:gender_name, &"Gender #{&1}"),
      position: 0,
      account: nil
    }
  end

  # ── Emotion ──────────────────────────────────────────────────────────

  def emotion_factory do
    %Emotion{
      name: sequence(:emotion_name, &"Emotion #{&1}"),
      position: 0,
      account: nil
    }
  end

  # ── Photo ────────────────────────────────────────────────────────────

  def photo_factory do
    contact = build(:contact)

    %Photo{
      contact: contact,
      account: contact.account,
      file_name: sequence(:photo_file, &"photo_#{&1}.jpg"),
      storage_key: sequence(:photo_key, &"contacts/photos/#{&1}.jpg"),
      file_size: 12345,
      content_type: "image/jpeg"
    }
  end

  # ── Document ─────────────────────────────────────────────────────────

  def document_factory do
    contact = build(:contact)

    %Document{
      contact: contact,
      account: contact.account,
      file_name: sequence(:doc_file, &"document_#{&1}.pdf"),
      storage_key: sequence(:doc_key, &"contacts/docs/#{&1}.pdf"),
      file_size: 54321,
      content_type: "application/pdf"
    }
  end

  # ── AuditLog ─────────────────────────────────────────────────────────

  def audit_log_factory do
    %AuditLog{
      account: build(:account),
      event: "contact_created",
      user_id: sequence(:audit_user_id, & &1),
      user_name: sequence(:audit_user_name, &"Admin User #{&1}"),
      metadata: %{}
    }
  end

  # ── AccountInvitation ────────────────────────────────────────────────

  def invitation_factory do
    account = build(:account)

    %AccountInvitation{
      account: account,
      invited_by: build(:user, account: account),
      email: sequence(:invite_email, &"invite#{&1}@example.com"),
      token_hash: :crypto.strong_rand_bytes(32),
      role: "viewer",
      expires_at: DateTime.add(DateTime.utc_now(:second), 7, :day)
    }
  end

  # ── ImmichCandidate ──────────────────────────────────────────────────

  def immich_candidate_factory do
    contact = build(:contact)

    %ImmichCandidate{
      contact: contact,
      account: contact.account,
      immich_photo_id: sequence(:immich_id, &"immich-photo-#{&1}"),
      immich_server_url: "https://immich.example.com",
      thumbnail_url: sequence(:immich_thumb, &"https://immich.example.com/thumb/#{&1}.jpg"),
      suggested_at: DateTime.utc_now(:second),
      status: "pending"
    }
  end

  # ── DuplicateCandidate ─────────────────────────────────────────────
  def duplicate_candidate_factory do
    account = build(:account)

    %Kith.Contacts.DuplicateCandidate{
      account: account,
      contact: build(:contact, account: account),
      duplicate_contact: build(:contact, account: account),
      score: 0.85,
      reasons: ["name_match"],
      status: "pending",
      detected_at: DateTime.utc_now(:second)
    }
  end

  # ── Gift ────────────────────────────────────────────────────────────
  def gift_factory do
    contact = build(:contact)

    %Gift{
      account: contact.account,
      contact: contact,
      creator: build(:user, account: contact.account),
      name: sequence(:gift_name, &"Gift #{&1}"),
      direction: "given",
      status: "idea",
      is_private: true
    }
  end

  def received_gift_factory do
    build(:gift, direction: "received", status: "received")
  end

  # ── Debt ────────────────────────────────────────────────────────────
  def debt_factory do
    contact = build(:contact)

    %Debt{
      account: contact.account,
      contact: contact,
      creator: build(:user, account: contact.account),
      title: sequence(:debt_title, &"Debt #{&1}"),
      amount: Decimal.new("100.00"),
      direction: "owed_to_me",
      status: "active",
      is_private: true
    }
  end

  def settled_debt_factory do
    build(:debt, status: "settled", settled_at: DateTime.utc_now(:second))
  end

  def debt_payment_factory do
    debt = build(:debt)

    %DebtPayment{
      debt: debt,
      account: debt.account,
      amount: Decimal.new("50.00"),
      paid_at: Date.utc_today()
    }
  end

  # ── Conversation ───────────────────────────────────────────────────
  def conversation_factory do
    contact = build(:contact)

    %Kith.Conversations.Conversation{
      account: contact.account,
      contact: contact,
      creator: build(:user, account: contact.account),
      subject: sequence(:conversation_subject, &"Conversation #{&1}"),
      platform: "other",
      status: "active",
      is_private: true
    }
  end

  # ── Message ────────────────────────────────────────────────────────
  def message_factory do
    conversation = build(:conversation)

    %Kith.Conversations.Message{
      conversation: conversation,
      account: conversation.account,
      body: sequence(:message_body, &"Message #{&1}"),
      direction: "sent",
      sent_at: DateTime.utc_now(:second)
    }
  end

  # ── Reference Data (global, nullable account_id) ─────────────────────

  def life_event_type_factory do
    %LifeEventType{
      name: sequence(:let_name, &"Life Event Type #{&1}"),
      icon: "star",
      category: "General",
      position: 0,
      account: nil
    }
  end

  def activity_type_category_factory do
    %ActivityTypeCategory{
      name: sequence(:atc_name, &"Activity Category #{&1}"),
      icon: "activity",
      position: 0,
      account: nil
    }
  end

  def call_direction_factory do
    %CallDirection{
      name: sequence(:cd_name, &"Direction #{&1}"),
      position: 0
    }
  end

  def currency_factory do
    %Currency{
      code: sequence(:currency_code, &"X#{String.pad_leading(to_string(&1), 2, "0")}"),
      name: sequence(:currency_name, &"Test Currency #{&1}"),
      symbol: "$"
    }
  end

  # ── Journal Entry ──────────────────────────────────────────────────

  def journal_entry_factory do
    account = build(:account)

    %Kith.Journal.Entry{
      account: account,
      author: build(:user, account: account),
      title: sequence(:journal_title, &"Journal Entry #{&1}"),
      content: "<p>Today was a good day.</p>",
      occurred_at: DateTime.utc_now(:second),
      mood: "good",
      is_private: true
    }
  end

  # ── Convenience Helpers ──────────────────────────────────────────────

  @doc """
  Creates an account + admin user pair for common test setup.

  Returns `{account, user}`.

  ## Options

    * `:role` - user role, default "admin"
    * `:timezone` - account timezone, default "Etc/UTC"
    * `:send_hour` - account send_hour, default 9

  ## Examples

      {account, admin} = setup_account()
      {account, viewer} = setup_account(role: "viewer")
      {account, admin} = setup_account(timezone: "America/New_York")
  """
  def setup_account(opts \\ []) do
    role = Keyword.get(opts, :role, "admin")
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    send_hour = Keyword.get(opts, :send_hour, 9)

    account = insert(:account, timezone: timezone, send_hour: send_hour)
    user = insert(:user, account: account, role: role)
    {account, user}
  end
end
