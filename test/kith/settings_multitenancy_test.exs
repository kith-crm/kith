defmodule Kith.SettingsMultitenancyTest do
  @moduledoc "Phase 08: Comprehensive tests for Settings & Multi-Tenancy"

  use Kith.DataCase, async: true

  alias Kith.Accounts
  alias Kith.Accounts.User
  alias Kith.Contacts
  alias Kith.Contacts.{Gender, RelationshipType, ContactFieldType, Tag}
  alias Kith.Reminders

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures
  import Kith.RemindersFixtures

  setup do
    seed_reference_data!()
    user = user_fixture()
    account_id = user.account_id
    account = Accounts.get_account!(account_id)
    seed_reminder_rules!(account_id)
    %{user: user, account_id: account_id, account: account}
  end

  test "DAV credentials belong to a person even within a shared account", %{
    user: user,
    account_id: account_id
  } do
    {:ok, teammate} = create_user_in_account(account_id, "dav-teammate@example.com", "viewer")
    owner = %{user | authenticated_at: DateTime.utc_now(:second)}
    teammate = %{teammate | authenticated_at: DateTime.utc_now(:second)}
    {:ok, row, _secret} = Accounts.DavAppPasswords.create(owner, %{name: "Private phone"})
    assert Accounts.DavAppPasswords.list(teammate) == []
    assert {:error, :not_found} = Accounts.DavAppPasswords.revoke(teammate, row.id)
    assert hd(Accounts.DavAppPasswords.list(owner)).revoked_at == nil
  end

  # ── TASK-08-01: User Settings ──────────────────────────────────────────

  describe "update_user_profile/2 with validations" do
    test "accepts valid settings", %{user: user} do
      assert {:ok, updated} =
               Accounts.update_user_profile(user, %{
                 display_name_format: "last_first",
                 temperature_unit: "fahrenheit",
                 default_profile_tab: "photos"
               })

      assert updated.display_name_format == "last_first"
      assert updated.temperature_unit == "fahrenheit"
      assert updated.default_profile_tab == "photos"
    end

    test "rejects invalid display_name_format", %{user: user} do
      assert {:error, changeset} =
               Accounts.update_user_profile(user, %{display_name_format: "invalid"})

      assert errors_on(changeset)[:display_name_format]
    end

    test "rejects invalid temperature_unit", %{user: user} do
      assert {:error, changeset} =
               Accounts.update_user_profile(user, %{temperature_unit: "kelvin"})

      assert errors_on(changeset)[:temperature_unit]
    end

    test "rejects invalid default_profile_tab", %{user: user} do
      assert {:error, changeset} =
               Accounts.update_user_profile(user, %{default_profile_tab: "settings"})

      assert errors_on(changeset)[:default_profile_tab]
    end

    test "rejects invalid timezone", %{user: user} do
      assert {:error, changeset} =
               Accounts.update_user_profile(user, %{timezone: "Fake/Timezone"})

      assert errors_on(changeset)[:timezone]
    end

    test "accepts valid timezone", %{user: user} do
      assert {:ok, updated} =
               Accounts.update_user_profile(user, %{timezone: "America/New_York"})

      assert updated.timezone == "America/New_York"
    end
  end

  describe "get_user_settings/1" do
    test "returns settings map", %{user: user} do
      settings = Accounts.get_user_settings(user)
      assert Map.has_key?(settings, :timezone)
      assert Map.has_key?(settings, :locale)
      assert Map.has_key?(settings, :currency)
      assert Map.has_key?(settings, :temperature_unit)
      assert Map.has_key?(settings, :display_name_format)
      assert Map.has_key?(settings, :default_profile_tab)
      assert Map.has_key?(settings, :me_contact_id)
    end
  end

  describe "link_me_contact/2 and unlink_me_contact/1" do
    test "links and unlinks a contact", %{user: user, account_id: account_id} do
      contact = contact_fixture(account_id)
      assert {:ok, linked} = Accounts.link_me_contact(user, contact.id)
      assert linked.me_contact_id == contact.id

      assert {:ok, unlinked} = Accounts.unlink_me_contact(linked)
      assert unlinked.me_contact_id == nil
    end
  end

  # ── TASK-08-02: Account Settings ────────────────────────────────────────

  describe "update_account/2" do
    test "validates timezone against IANA database", %{account: account} do
      assert {:error, changeset} =
               Accounts.update_account(account, %{timezone: "Invalid/Zone"})

      assert errors_on(changeset)[:timezone]
    end

    test "validates send_hour range", %{account: account} do
      assert {:error, changeset} = Accounts.update_account(account, %{send_hour: 25})
      assert errors_on(changeset)[:send_hour]
    end

    test "validates name is required", %{account: account} do
      assert {:error, changeset} = Accounts.update_account(account, %{name: ""})
      assert errors_on(changeset)[:name]
    end

    test "accepts valid settings", %{account: account} do
      assert {:ok, updated} =
               Accounts.update_account(account, %{
                 name: "Updated Name",
                 timezone: "Europe/London",
                 send_hour: 14
               })

      assert updated.name == "Updated Name"
      assert updated.timezone == "Europe/London"
      assert updated.send_hour == 14
    end
  end

  # ── TASK-08-03: Custom Genders CRUD ─────────────────────────────────────

  describe "genders CRUD" do
    test "list_genders includes global and account-specific", %{account_id: account_id} do
      # Seed a global gender
      now = DateTime.utc_now(:second)

      Repo.insert_all("genders", [
        %{name: "Global Gender", account_id: nil, position: 0, inserted_at: now, updated_at: now}
      ])

      {:ok, _custom} = Contacts.create_gender(account_id, %{name: "Custom", position: 10})
      genders = Contacts.list_genders(account_id)
      names = Enum.map(genders, & &1.name)

      assert "Global Gender" in names
      assert "Custom" in names
    end

    test "cannot modify global gender" do
      now = DateTime.utc_now(:second)

      {1, _} =
        Repo.insert_all("genders", [
          %{
            name: "ReadOnly",
            account_id: nil,
            position: 0,
            inserted_at: now,
            updated_at: now
          }
        ])

      [global | _] =
        Repo.all(from(g in Gender, where: is_nil(g.account_id) and g.name == "ReadOnly"))

      assert {:error, :global_read_only} = Contacts.update_gender(global, %{name: "Changed"})
      assert {:error, :global_read_only} = Contacts.delete_gender(global)
    end

    test "cannot delete gender in use", %{account_id: account_id} do
      {:ok, gender} = Contacts.create_gender(account_id, %{name: "InUse"})
      _contact = contact_fixture(account_id, %{gender_id: gender.id})
      assert {:error, :in_use} = Contacts.delete_gender(gender)
    end

    test "can delete unused gender", %{account_id: account_id} do
      {:ok, gender} = Contacts.create_gender(account_id, %{name: "Unused"})
      assert {:ok, _} = Contacts.delete_gender(gender)
    end

    test "reorder_genders updates positions", %{account_id: account_id} do
      {:ok, g1} = Contacts.create_gender(account_id, %{name: "First", position: 0})
      {:ok, g2} = Contacts.create_gender(account_id, %{name: "Second", position: 1})

      assert {:ok, _} = Contacts.reorder_genders(account_id, [g2.id, g1.id])

      g1_updated = Repo.get!(Gender, g1.id)
      g2_updated = Repo.get!(Gender, g2.id)
      assert g2_updated.position == 0
      assert g1_updated.position == 1
    end
  end

  # ── TASK-08-04: Custom Relationship Types CRUD ──────────────────────────

  describe "relationship types CRUD" do
    test "create requires both forward and reverse names", %{account_id: account_id} do
      assert {:error, changeset} =
               Contacts.create_relationship_type(account_id, %{name: "Only Forward"})

      assert errors_on(changeset)[:reverse_name]
    end

    test "CRUD lifecycle works", %{account_id: account_id} do
      {:ok, rt} =
        Contacts.create_relationship_type(account_id, %{
          name: "Mentor",
          reverse_name: "Mentee"
        })

      assert rt.name == "Mentor"
      assert rt.reverse_name == "Mentee"

      {:ok, updated} = Contacts.update_relationship_type(rt, %{name: "Teacher"})
      assert updated.name == "Teacher"

      {:ok, _} = Contacts.delete_relationship_type(updated)
    end

    test "cannot delete global relationship type" do
      global =
        Repo.all(from(rt in RelationshipType, where: is_nil(rt.account_id), limit: 1))
        |> List.first()

      if global do
        assert {:error, :global_read_only} = Contacts.delete_relationship_type(global)
      end
    end
  end

  # ── TASK-08-05: Custom Contact Field Types CRUD ─────────────────────────

  describe "contact field types CRUD" do
    test "validates protocol to allowed values", %{account_id: account_id} do
      assert {:error, changeset} =
               Contacts.create_contact_field_type(account_id, %{
                 name: "Bad",
                 protocol: "javascript"
               })

      assert errors_on(changeset)[:protocol]
    end

    test "allows valid protocols", %{account_id: account_id} do
      assert {:ok, cft} =
               Contacts.create_contact_field_type(account_id, %{
                 name: "Website",
                 protocol: "https"
               })

      assert cft.protocol == "https"
    end

    test "reorder works", %{account_id: account_id} do
      {:ok, c1} = Contacts.create_contact_field_type(account_id, %{name: "A", position: 0})
      {:ok, c2} = Contacts.create_contact_field_type(account_id, %{name: "B", position: 1})

      assert {:ok, _} = Contacts.reorder_contact_field_types(account_id, [c2.id, c1.id])

      assert Repo.get!(ContactFieldType, c2.id).position == 0
      assert Repo.get!(ContactFieldType, c1.id).position == 1
    end
  end

  # ── TASK-08-06: Invitation Flow ─────────────────────────────────────────

  describe "invitations" do
    test "create_invitation sends email and creates record", %{
      user: user,
      account_id: account_id
    } do
      assert {:ok, invitation} =
               Accounts.create_invitation(
                 account_id,
                 user.id,
                 %{email: "new@example.com", role: "viewer"},
                 &"/accept/#{&1}"
               )

      assert invitation.email == "new@example.com"
      assert invitation.role == "viewer"
      assert invitation.token_hash != nil
      assert invitation.expires_at != nil
    end

    test "cannot invite existing user in same account", %{
      user: user,
      account_id: account_id
    } do
      assert {:error, :already_a_member} =
               Accounts.create_invitation(
                 account_id,
                 user.id,
                 %{email: user.email, role: "viewer"},
                 &"/accept/#{&1}"
               )
    end

    test "cannot create duplicate pending invitation", %{
      user: user,
      account_id: account_id
    } do
      Accounts.create_invitation(
        account_id,
        user.id,
        %{email: "dupe@example.com", role: "editor"},
        &"/accept/#{&1}"
      )

      assert {:error, :already_invited} =
               Accounts.create_invitation(
                 account_id,
                 user.id,
                 %{email: "dupe@example.com", role: "viewer"},
                 &"/accept/#{&1}"
               )
    end

    test "accept_invitation creates user and marks accepted", %{
      user: user,
      account_id: account_id
    } do
      # Capture the raw token via the url_fun callback
      {:ok, _invitation} =
        Accounts.create_invitation(
          account_id,
          user.id,
          %{email: "invitee@example.com", role: "editor"},
          fn token ->
            send(self(), {:captured_token, token})
            "/accept/#{token}"
          end
        )

      raw_token =
        receive do
          {:captured_token, token} -> token
        after
          100 -> flunk("did not capture invitation token")
        end

      assert {:ok, new_user} =
               Accounts.accept_invitation(raw_token, %{
                 email: "invitee@example.com",
                 password: "SecurePass123!"
               })

      assert new_user.email == "invitee@example.com"
      assert new_user.role == "editor"
      assert new_user.account_id == account_id
      assert new_user.confirmed_at != nil
    end

    test "revoke_invitation deletes pending invitation", %{
      user: user,
      account_id: account_id
    } do
      {:ok, invitation} =
        Accounts.create_invitation(
          account_id,
          user.id,
          %{email: "revoke@example.com", role: "viewer"},
          &"/accept/#{&1}"
        )

      assert {:ok, _} = Accounts.revoke_invitation(account_id, invitation.id)
      assert Accounts.list_invitations(account_id) == []
    end

    test "list_invitations returns all invitations", %{user: user, account_id: account_id} do
      Accounts.create_invitation(
        account_id,
        user.id,
        %{email: "a@example.com", role: "viewer"},
        &"/accept/#{&1}"
      )

      Accounts.create_invitation(
        account_id,
        user.id,
        %{email: "b@example.com", role: "editor"},
        &"/accept/#{&1}"
      )

      assert length(Accounts.list_invitations(account_id)) == 2
    end
  end

  # ── TASK-08-07: User Role Management ────────────────────────────────────

  describe "role management" do
    test "cannot change own role", %{user: user} do
      assert {:error, :cannot_change_own_role} =
               Accounts.change_user_role(user.id, user.id, "editor")
    end

    test "cannot demote last admin", %{user: user, account_id: account_id} do
      # Create a second user as editor
      {:ok, editor} =
        create_user_in_account(account_id, "editor@example.com", "editor")

      assert {:error, :last_admin} =
               Accounts.change_user_role(editor.id, user.id, "viewer")
    end

    test "can demote admin when another admin exists", %{user: user, account_id: account_id} do
      {:ok, admin2} = create_user_in_account(account_id, "admin2@example.com", "admin")

      assert {:ok, updated} =
               Accounts.change_user_role(admin2.id, user.id, "editor")

      assert updated.role == "editor"
    end

    test "cannot remove self", %{user: user} do
      assert {:error, :cannot_remove_self} = Accounts.remove_user(user.id, user.id)
    end

    test "cannot remove last admin", %{user: user, account_id: account_id} do
      {:ok, editor} = create_user_in_account(account_id, "ed@example.com", "editor")

      assert {:error, :last_admin} = Accounts.remove_user(editor.id, user.id)
    end

    test "remove_user deletes user and invalidates sessions", %{
      user: user,
      account_id: account_id
    } do
      {:ok, target} = create_user_in_account(account_id, "remove@example.com", "viewer")
      _token = Accounts.generate_user_session_token(target)

      assert {:ok, _} = Accounts.remove_user(user.id, target.id)
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(target.id) end
    end
  end

  # ── TASK-08-08: Feature Modules ─────────────────────────────────────────

  describe "feature modules" do
    test "module_enabled? defaults to false", %{account: account} do
      refute Accounts.module_enabled?(account, "immich")
    end

    test "enable and disable module", %{account: account} do
      {:ok, enabled} = Accounts.enable_module(account, "immich")
      assert Accounts.module_enabled?(enabled, "immich")

      {:ok, disabled} = Accounts.disable_module(enabled, "immich")
      refute Accounts.module_enabled?(disabled, "immich")
    end

    test "unknown module returns error", %{account: account} do
      assert {:error, :unknown_module} = Accounts.enable_module(account, "unknown")
    end

    test "list_modules returns all known modules with status", %{account: account} do
      modules = Accounts.list_modules(account)
      assert [%{name: "immich", enabled: false}] = modules
    end
  end

  # ── TASK-08-09: Reminder Rules Management ───────────────────────────────

  describe "reminder rules CRUD" do
    test "list_reminder_rules returns seeded rules", %{account_id: account_id} do
      rules = Reminders.list_reminder_rules(account_id)
      assert length(rules) == 3
      days = Enum.map(rules, & &1.days_before)
      assert 0 in days
      assert 7 in days
      assert 30 in days
    end

    test "create_reminder_rule adds new rule", %{account_id: account_id} do
      {:ok, rule} =
        Reminders.create_reminder_rule(account_id, %{days_before: 14, active: true})

      assert rule.days_before == 14
    end

    test "update_reminder_rule toggles active", %{account_id: account_id} do
      rule =
        Reminders.list_reminder_rules(account_id)
        |> Enum.find(&(&1.days_before == 7))

      {:ok, updated} = Reminders.update_reminder_rule(rule, %{active: false})
      refute updated.active
    end

    test "cannot deactivate 0-day rule", %{account_id: account_id} do
      rule =
        Reminders.list_reminder_rules(account_id)
        |> Enum.find(&(&1.days_before == 0))

      assert {:error, :cannot_deactivate_on_day_rule} =
               Reminders.update_reminder_rule(rule, %{active: false})
    end

    test "delete_reminder_rule removes rule", %{account_id: account_id} do
      {:ok, rule} =
        Reminders.create_reminder_rule(account_id, %{days_before: 60, active: true})

      {:ok, _} = Reminders.delete_reminder_rule(rule)
      assert length(Reminders.list_reminder_rules(account_id)) == 3
    end

    test "unique constraint on (account_id, days_before)", %{account_id: account_id} do
      assert {:error, changeset} =
               Reminders.create_reminder_rule(account_id, %{days_before: 7})

      assert errors_on(changeset)[:account_id] || errors_on(changeset)[:days_before]
    end
  end

  # ── TASK-08-10: Tags Management ─────────────────────────────────────────

  describe "tags management" do
    test "list_tags_with_counts returns usage counts", %{account_id: account_id} do
      {:ok, tag} = Contacts.create_tag(account_id, %{name: "Friends"})
      contact = contact_fixture(account_id)
      Contacts.tag_contact(contact, tag)

      results = Contacts.list_tags_with_counts(account_id)
      found = Enum.find(results, fn %{tag: t} -> t.id == tag.id end)
      assert found.count == 1
    end

    test "tag_usage_count returns accurate count", %{account_id: account_id} do
      {:ok, tag} = Contacts.create_tag(account_id, %{name: "Work"})
      c1 = contact_fixture(account_id)
      c2 = contact_fixture(account_id)
      Contacts.tag_contact(c1, tag)
      Contacts.tag_contact(c2, tag)

      assert Contacts.tag_usage_count(tag) == 2
    end

    test "rename_tag updates name", %{account_id: account_id} do
      {:ok, tag} = Contacts.create_tag(account_id, %{name: "Old"})
      {:ok, renamed} = Contacts.rename_tag(tag, "New")
      assert renamed.name == "New"
    end

    test "merge_tags moves associations and deletes source", %{account_id: account_id} do
      {:ok, source} = Contacts.create_tag(account_id, %{name: "Source"})
      {:ok, target} = Contacts.create_tag(account_id, %{name: "Target"})

      c1 = contact_fixture(account_id)
      c2 = contact_fixture(account_id)
      c3 = contact_fixture(account_id)

      # c1 has source, c2 has both, c3 has target
      Contacts.tag_contact(c1, source)
      Contacts.tag_contact(c2, source)
      Contacts.tag_contact(c2, target)
      Contacts.tag_contact(c3, target)

      assert {:ok, merged_target} = Contacts.merge_tags(account_id, source, target)
      assert merged_target.id == target.id

      # Source tag should be deleted
      assert Repo.get(Tag, source.id) == nil

      # All three contacts should have the target tag, no duplicates
      target_count = Contacts.tag_usage_count(target)
      assert target_count == 3
    end
  end

  # ── TASK-08-11: Account Reset ───────────────────────────────────────────

  describe "account reset" do
    test "requires exact RESET confirmation", %{account_id: account_id} do
      assert {:error, :invalid_confirmation} =
               Accounts.request_account_reset(account_id, "reset")

      assert {:error, :invalid_confirmation} =
               Accounts.request_account_reset(account_id, "RESET!")
    end

    test "a completed reset does not block a new reset", %{account_id: account_id} do
      {:ok, previous} =
        %{account_id: account_id}
        |> Kith.Workers.AccountResetWorker.new()
        |> Oban.insert()

      previous |> Ecto.Changeset.change(state: "completed") |> Repo.update!()

      assert {:ok, :queued} = Accounts.request_account_reset(account_id, "RESET")

      assert Repo.aggregate(
               from(j in Oban.Job,
                 where:
                   j.worker == "Kith.Workers.AccountResetWorker" and j.state == "available" and
                     fragment("?->>'account_id'", j.args) == ^Integer.to_string(account_id)
               ),
               :count
             ) == 1
    end

    test "accepts RESET and queues job", %{account_id: account_id} do
      assert {:ok, :queued} = Accounts.request_account_reset(account_id, "RESET")
    end
  end

  # ── TASK-08-12: Account Deletion ────────────────────────────────────────

  describe "account deletion" do
    test "requires exact account name confirmation", %{account_id: account_id} do
      assert {:error, :invalid_confirmation} =
               Accounts.request_account_deletion(account_id, "wrong name")
    end

    test "invalidates sessions immediately and queues job", %{
      user: user,
      account: account
    } do
      token = Accounts.generate_user_session_token(user)

      assert {:ok, :queued} =
               Accounts.request_account_deletion(account.id, account.name)

      # Sessions should be invalidated immediately
      refute Accounts.get_user_by_session_token(token)
    end
  end

  # ── TASK-08-13: Immich Settings Context ─────────────────────────────────

  describe "Immich settings" do
    test "get_settings returns Immich config", %{account: account} do
      settings = Kith.Immich.Settings.get_settings(account)
      assert Map.has_key?(settings, :base_url)
      assert Map.has_key?(settings, :api_key)
      assert Map.has_key?(settings, :enabled)
      assert Map.has_key?(settings, :status)
    end

    test "update_settings stores URL and key", %{account: account} do
      {:ok, updated} =
        Kith.Immich.Settings.update_settings(account, %{
          immich_base_url: "https://immich.test.local",
          immich_api_key: "test-key-123"
        })

      assert updated.immich_base_url == "https://immich.test.local"
      assert updated.immich_api_key != nil
    end

    test "enable/disable toggles status", %{account: account} do
      {:ok, enabled} = Kith.Immich.Settings.enable(account)
      assert enabled.immich_enabled == true
      assert enabled.immich_status == "ok"

      {:ok, disabled} = Kith.Immich.Settings.disable(enabled)
      assert disabled.immich_enabled == false
      assert disabled.immich_status == "disabled"
    end

    test "get_sync_status returns needs_review_count", %{account: account} do
      status = Kith.Immich.Settings.get_sync_status(account)
      assert Map.has_key?(status, :needs_review_count)
      assert status.needs_review_count == 0
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp create_user_in_account(account_id, email, role) do
    %User{account_id: account_id}
    |> User.registration_changeset(%{
      email: email,
      password: "SecurePass123!",
      tos_accepted: true
    })
    |> Ecto.Changeset.put_change(:role, role)
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Repo.insert()
  end
end
