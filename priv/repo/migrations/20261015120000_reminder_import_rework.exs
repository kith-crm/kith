defmodule Kith.Repo.Migrations.ReminderImportRework do
  use Ecto.Migration

  def up do
    alter table(:reminders) do
      add :description, :text
    end

    drop constraint(:reminders, :reminders_interval_unit_values)

    create constraint(:reminders, :reminders_interval_unit_values,
             check: "interval_unit IN ('day', 'week', 'month', 'year') OR interval_unit IS NULL"
           )

    alter table(:contacts) do
      add :first_met_reminder, :boolean, null: false, default: false
    end

    create unique_index(:reminders, [:contact_id],
             where: "type = 'first_met'",
             name: :reminders_first_met_unique_idx
           )
  end

  def down do
    drop index(:reminders, [:contact_id], name: :reminders_first_met_unique_idx)

    alter table(:contacts) do
      remove :first_met_reminder
    end

    # Neither can first-met rows (the old type check and dispatcher don't know
    # them), nor day-interval rows the old interval constraint.
    execute "DELETE FROM reminders WHERE type = 'first_met'"
    execute "DELETE FROM reminders WHERE interval_unit = 'day'"
    drop constraint(:reminders, :reminders_interval_unit_values)

    create constraint(:reminders, :reminders_interval_unit_values,
             check: "interval_unit IN ('week', 'month', 'year') OR interval_unit IS NULL"
           )

    alter table(:reminders) do
      remove :description
    end
  end
end
