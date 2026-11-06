defmodule Kith.Workers.ReminderEmailWorkerFailureTest do
  use Kith.DataCase, async: false
  use Oban.Testing, repo: Kith.Repo

  import Ecto.Query
  import Swoosh.TestAssertions

  alias Kith.Reminders
  alias Kith.Reminders.{Dispatcher, Reminder, ReminderInstance}
  alias Kith.Workers.ReminderEmailWorker

  import Kith.ReminderEmailFixtures

  setup do
    setup_fixture()
  end

  defmodule FailingAdapter do
    @moduledoc false
    use Swoosh.Adapter

    @impl Swoosh.Adapter
    def deliver(_email, _config), do: {:error, :boom}
  end

  defmodule GatedFailingAdapter do
    @moduledoc false
    use Swoosh.Adapter

    @impl Swoosh.Adapter
    def deliver(_email, config) do
      send(Keyword.fetch!(config, :gate_owner), {:delivery_started, self()})

      receive do
        :fail_delivery -> {:error, :boom}
      after
        5_000 -> raise "mail delivery gate was not released"
      end
    end
  end

  for newer_state <- [:snoozed, :woken, :resolved] do
    @tag :capture_log
    test "a final delivery failure cannot overwrite #{newer_state} while SMTP is in flight",
         ctx do
      original = Application.fetch_env!(:kith, Kith.Mailer)

      Kith.TestEnv.put_env_restoring(
        :kith,
        Kith.Mailer,
        original |> Keyword.put(:adapter, GatedFailingAdapter) |> Keyword.put(:gate_owner, self())
      )

      # SMTP is outside a DB transaction. The gate proves eligibility was
      # checked before the user action; no sleeps or concurrent SQL are needed
      # to exercise the late response's stale snapshot.
      task =
        Task.async(fn ->
          perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id, snooze_count: 0},
            attempt: 3
          )
        end)

      assert_receive {:delivery_started, worker}, 5_000

      expected =
        case unquote(newer_state) do
          :snoozed ->
            {:ok, snoozed} = Reminders.snooze_instance(ctx.instance, "one_hour")
            snoozed

          :woken ->
            {:ok, snoozed} = Reminders.snooze_instance(ctx.instance, "one_hour")
            :ok = Dispatcher.run(DateTime.add(snoozed.snoozed_until, 1, :second))
            assert %{status: "pending", snooze_count: 1} = Repo.reload!(snoozed)

          :resolved ->
            ctx.instance |> ReminderInstance.resolve_changeset() |> Repo.update!()
        end

      send(worker, :fail_delivery)
      assert {:error, :boom} = Task.await(task, 5_000)
      assert Repo.reload!(ctx.instance) == expected
      refute_email_sent()
    end
  end

  @tag :capture_log
  test "a final failure rearms stay-in-touch using an interval edited during SMTP", ctx do
    today = Date.utc_today()

    {:ok, reminder} =
      Reminders.create_reminder(ctx.user.account_id, ctx.user.id, %{
        type: "stay_in_touch",
        title: "Reach out",
        interval_unit: "day",
        interval_count: 7,
        anchor_date: today,
        contact_id: ctx.contact.id
      })

    :ok = dispatch_today(ctx.user.account_id)
    instance = Repo.one!(from(i in ReminderInstance, where: i.reminder_id == ^reminder.id))
    ctx = Map.put(ctx, :instance, instance)
    original = Application.fetch_env!(:kith, Kith.Mailer)

    Kith.TestEnv.put_env_restoring(
      :kith,
      Kith.Mailer,
      original |> Keyword.put(:adapter, GatedFailingAdapter) |> Keyword.put(:gate_owner, self())
    )

    task =
      Task.async(fn ->
        perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id, snooze_count: 0},
          attempt: 3
        )
      end)

    assert_receive {:delivery_started, worker}, 5_000
    {:ok, _edited} = Reminders.update_reminder(reminder, %{interval_count: 21})
    send(worker, :fail_delivery)
    assert {:error, :boom} = Task.await(task, 5_000)

    assert %{status: "failed"} = Repo.reload!(ctx.instance)

    assert %{interval_unit: "day", interval_count: 21, next_reminder_date: next} =
             Repo.reload!(reminder)

    assert next == Date.add(today, 21)
    refute_email_sent()
  end

  defp fail_mail(_ctx) do
    original = Application.get_env(:kith, Kith.Mailer)
    Application.put_env(:kith, Kith.Mailer, Keyword.put(original, :adapter, FailingAdapter))
    on_exit(fn -> Application.put_env(:kith, Kith.Mailer, original) end)
    :ok
  end

  @tag :capture_log
  test "a failed queued delivery retries successfully without changing the notice", ctx do
    [job] = all_enqueued(worker: ReminderEmailWorker)
    original_mailer = Application.fetch_env!(:kith, Kith.Mailer)
    :ok = fail_mail(ctx)
    assert %{failure: 1, success: 0} = Oban.drain_queue(queue: :reminders)
    assert %{state: "retryable", attempt: 1} = Repo.reload!(job)
    assert %{id: id, status: "pending", snooze_count: 0} = Repo.reload!(ctx.instance)
    assert id == ctx.instance.id
    refute_email_sent()

    Application.put_env(:kith, Kith.Mailer, original_mailer)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :reminders, with_scheduled: true)
    assert %{state: "completed", attempt: 2} = Repo.reload!(job)
    assert_email_sent(to: {ctx.user.email, ctx.user.email}, subject: "Reminder: Call Mona")
    refute_email_sent()

    assert Repo.all(
             from(i in ReminderInstance, where: i.reminder_id == ^ctx.instance.reminder_id)
           ) == [ctx.instance]

    audits =
      Repo.all(
        from(a in Kith.AuditLogs.AuditLog,
          where: a.account_id == ^ctx.user.account_id and a.event == "reminder_fired",
          order_by: a.id
        )
      )

    assert [failed, succeeded] = audits
    assert failed.metadata["instance_id"] == ctx.instance.id
    assert failed.metadata["delivery_error"] == ":boom"
    assert succeeded.metadata["instance_id"] == ctx.instance.id
    refute Map.has_key?(succeeded.metadata, "delivery_error")
  end

  defp snooze_and_wake(instance) do
    {:ok, snoozed} = Reminders.snooze_instance(Repo.reload!(instance), "one_hour")
    :ok = Dispatcher.run(DateTime.add(snoozed.snoozed_until, 1, :second))
    Repo.reload!(snoozed)
  end

  defp assert_one_delivery do
    assert_email_sent(subject: "Reminder: Call Mona")
    refute_email_sent()
  end

  @tag :capture_log
  test "a retryable original job cannot send after a later snooze wakes", ctx do
    [original] = all_enqueued(worker: ReminderEmailWorker)
    original_mailer = Application.get_env(:kith, Kith.Mailer)
    :ok = fail_mail(ctx)

    assert %{failure: 1, success: 0} = Oban.drain_queue(queue: :reminders)
    assert Repo.reload!(original).state == "retryable"
    Application.put_env(:kith, Kith.Mailer, original_mailer)

    snooze_and_wake(ctx.instance)

    assert %{discard: 1, success: 1, failure: 0} =
             Oban.drain_queue(queue: :reminders, with_scheduled: true)

    assert %{state: "discarded", attempt: 2} = Repo.reload!(original)
    assert_one_delivery()
  end

  describe "eligibility changes between delivery attempts" do
    setup :fail_mail

    for blocked <- [:inactive, :deleted, :archived, :resolved, :dismissed, :snoozed, :failed] do
      @tag :capture_log
      test "does not retry delivery after #{blocked}", ctx do
        assert {:error, :boom} =
                 perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id}, attempt: 1)

        block_delivery(ctx, unquote(blocked))
        before = Repo.get!(ReminderInstance, ctx.instance.id)

        assert {:discard, _} =
                 perform_job(ReminderEmailWorker, %{instance_id: ctx.instance.id}, attempt: 3)

        assert Repo.get!(ReminderInstance, ctx.instance.id) == before
      end
    end
  end

  describe "when delivery fails on the final attempt" do
    setup :fail_mail

    @tag :capture_log
    test "the instance is marked failed", %{instance: instance} do
      assert {:error, :boom} =
               perform_job(ReminderEmailWorker, %{instance_id: instance.id}, attempt: 3)

      assert Repo.get!(ReminderInstance, instance.id).status == "failed"
    end

    @tag :capture_log
    test "an earlier attempt leaves the instance pending", %{instance: instance} do
      assert {:error, :boom} =
               perform_job(ReminderEmailWorker, %{instance_id: instance.id}, attempt: 1)

      assert Repo.get!(ReminderInstance, instance.id).status == "pending"
    end

    @tag :capture_log
    test "a stay-in-touch reminder is re-armed one interval from today", ctx do
      today = Reminders.account_today(ctx.user.account_id)

      {:ok, reminder} =
        Reminders.create_reminder(ctx.user.account_id, ctx.user.id, %{
          type: "stay_in_touch",
          frequency: "monthly",
          anchor_date: today,
          contact_id: ctx.contact.id
        })

      :ok = dispatch_today(ctx.user.account_id)
      [instance] = Repo.all(from(i in ReminderInstance, where: i.reminder_id == ^reminder.id))

      assert {:error, :boom} =
               perform_job(ReminderEmailWorker, %{instance_id: instance.id}, attempt: 3)

      assert Repo.get!(ReminderInstance, instance.id).status == "failed"
      assert Repo.get!(Reminder, reminder.id).next_reminder_date == Date.shift(today, month: 1)
    end
  end
end
