defmodule Kith.Repo.Migrations.ReminderDispatcher do
  use Ecto.Migration

  # Runs on a fresh, empty database (production is reset for this release):
  # no backfill, and the new NOT NULL columns need no defaults.
  def change do
    alter table(:reminders) do
      remove :frequency, :string
      remove :enqueued_oban_job_ids, :jsonb, null: false, default: "[]"
      add :anchor_date, :date, null: false
      add :interval_unit, :string
      add :interval_count, :integer
    end

    create constraint(:reminders, :reminders_interval_unit_values,
             check: "interval_unit IN ('week', 'month', 'year') OR interval_unit IS NULL"
           )

    create constraint(:reminders, :reminders_interval_count_positive,
             check: "interval_count IS NULL OR interval_count >= 1"
           )

    alter table(:reminder_instances) do
      add :occurrence_date, :date, null: false
      add :kind, :string, null: false
      add :days_before, :integer, null: false
    end

    create constraint(:reminder_instances, :reminder_instances_kind_values,
             check: "kind IN ('on_day', 'advance')"
           )

    create unique_index(:reminder_instances, [:reminder_id, :occurrence_date, :days_before],
             name: :reminder_instances_occurrence_idx
           )
  end
end
