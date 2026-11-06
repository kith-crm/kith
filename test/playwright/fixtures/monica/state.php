<?php
// DB-level state the Monica API cannot set. Run inside the Monica container:
//   docker cp state.php kith-monica-e2e-monica-1:/tmp/state.php
//   docker exec kith-monica-e2e-monica-1 php /tmp/state.php [phase]
// Phases (seed.py calls the first two while seeding, at the point the reminder ids need them):
//   first_met <first> <last> <Y-m-d>   first-met date + reminder (UpdateContactIntroduction has no API)
//   life_event_type <name>             custom life-event type; prints its id (default types have NULL names, M11)
//   (none)                             final state: stay-in-touch on Gina, "One-time past (sent)" marked sent (M10)
require '/var/www/html/vendor/autoload.php';
$app = require '/var/www/html/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use App\Models\Contact\Contact;
use App\Models\Contact\Reminder;
use App\Services\Contact\Contact\UpdateContactIntroduction;
use App\Services\Account\LifeEvent\LifeEventType\CreateLifeEventType;
use App\Models\User\User;

$user = User::where('email', 'review@example.com')->firstOrFail();
$phase = $argv[1] ?? 'final';

function contact_by_name($first, $last)
{
    return Contact::where('first_name', $first)->where('last_name', $last)->firstOrFail();
}

if ($phase === 'first_met') {
    [$first, $last, $date] = [$argv[2], $argv[3], $argv[4]];
    $c = contact_by_name($first, $last);
    [$y, $m, $d] = array_map('intval', explode('-', $date));
    app(UpdateContactIntroduction::class)->execute([
        'account_id' => $user->account_id,
        'contact_id' => $c->id,
        'is_date_known' => true,
        'is_age_based' => false,
        'day' => $d, 'month' => $m, 'year' => $y,
        'add_reminder' => true,
    ]);
    echo "first_met ok\n";
} elseif ($phase === 'life_event_type') {
    $cat = \DB::table('life_event_categories')->where('account_id', $user->account_id)->orderBy('id')->first();
    $t = app(CreateLifeEventType::class)->execute([
        'account_id' => $user->account_id,
        'life_event_category_id' => $cat->id,
        'name' => $argv[2],
    ]);
    echo "TYPE_ID={$t->id}\n";
} else {
    // Gina: stay in touch every 14 days, trigger date today + 14 days (M12; UI-only in Monica).
    $gina = contact_by_name('Gina', 'E2E');
    \DB::table('contacts')->where('id', $gina->id)->update([
        'stay_in_touch_frequency' => 14,
        'stay_in_touch_trigger_date' => date('Y-m-d', strtotime('+14 days')) . ' 00:00:00',
    ]);
    // M10: a sent one-time reminder is inactive and has no outbox row; the API still returns it unchanged.
    $sent = Reminder::where('title', 'One-time past (sent)')->firstOrFail();
    \DB::table('reminders')->where('id', $sent->id)->update(['inactive' => 1]);
    \DB::table('reminder_outbox')->where('reminder_id', $sent->id)->delete();
    echo "state ok\n";
}
