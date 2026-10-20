<?php
// Creates the review user (verified) and a personal API token. Run via: docker exec <monica> php /tmp/bootstrap.php
require '/var/www/html/vendor/autoload.php';
$app = require '/var/www/html/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
use App\Models\Account\Account;
use App\Models\User\User;
$u = User::where('email', 'review@example.com')->first();
if (!$u) {
    $a = Account::createDefault('Review', 'User', 'review@example.com', 'review-password-1');
    $u = User::where('email', 'review@example.com')->first();
}
$u->email_verified_at = now();
$u->save();
if (\DB::table('oauth_personal_access_clients')->count() == 0) {
    \Artisan::call('passport:client', ['--personal' => true, '--name' => 'review', '--no-interaction' => true]);
}
$t = $u->createToken('review')->accessToken;
file_put_contents('/tmp/token.txt', $t);
echo "OK\n";
