defmodule Kith.Accounts.TosAcceptanceTest do
  # async: false — the ToS requirement is read from `Application.get_env/3`,
  # which is node-global. Flipping it inside an async case leaks into every
  # other case running at the same time: any concurrent test building a
  # registration changeset without `tos_accepted` fails, and this module's own
  # expectations get clobbered in return. ExUnit runs sync cases serially and
  # never alongside async ones, which is what makes the mutation safe here.
  use Kith.DataCase, async: false

  alias Kith.Accounts.User

  describe "registration_changeset with ToS required" do
    setup do
      original = Application.get_env(:kith, :require_tos_acceptance, false)
      Application.put_env(:kith, :require_tos_acceptance, true)
      on_exit(fn -> Application.put_env(:kith, :require_tos_acceptance, original) end)
      :ok
    end

    test "valid when tos_accepted is true" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "test@example.com",
          password: "valid_password123",
          tos_accepted: true
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :tos_accepted_at)
    end

    test "invalid when tos_accepted is false" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "test@example.com",
          password: "valid_password123",
          tos_accepted: false
        })

      refute changeset.valid?
      assert {"you must accept the Terms of Service", _} = changeset.errors[:tos_accepted]
    end

    test "invalid when tos_accepted is missing" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "test@example.com",
          password: "valid_password123"
        })

      refute changeset.valid?
      assert {"you must accept the Terms of Service", _} = changeset.errors[:tos_accepted]
    end
  end

  describe "registration_changeset without ToS required" do
    setup do
      original = Application.get_env(:kith, :require_tos_acceptance, false)
      Application.put_env(:kith, :require_tos_acceptance, false)
      on_exit(fn -> Application.put_env(:kith, :require_tos_acceptance, original) end)
      :ok
    end

    test "valid without tos_accepted" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "test@example.com",
          password: "valid_password123"
        })

      assert changeset.valid?
      refute Ecto.Changeset.get_change(changeset, :tos_accepted_at)
    end
  end
end
