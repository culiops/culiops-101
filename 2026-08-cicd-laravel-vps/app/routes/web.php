<?php

use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Redis;
use Illuminate\Support\Facades\Storage;
use App\Jobs\SendReceipt;

/*
| The whole app is deliberately tiny — just enough surface to reproduce the
| video's failure modes on a real request.
*/

// APP_VERSION is set in .env per release (e.g. the commit SHA). It's the marker
// we watch to prove which code a request / a worker is actually running.
Route::get('/', fn () => 'version: '.config('app.version'));

// /health — a REAL health check: it must TOUCH the database and Redis, not just
// return "ok". release.sh smoke-tests this; a check that verifies nothing hands
// you false confidence. Throwing here → non-2xx → auto-rollback.
Route::get('/health', function () {
    DB::select('select 1');            // DB reachable?
    Redis::connection()->ping();       // Redis reachable?
    return response()->json(['status' => 'ok', 'version' => config('app.version')]);
});

// Enqueue a job — used to demonstrate the "worker still runs old code" scar.
// The job records which APP_VERSION processed it (see App\Jobs\SendReceipt).
Route::get('/enqueue', function () {
    SendReceipt::dispatch();
    return 'queued on version: '.config('app.version');
});

// Reads a value the WRONG way (env() in app code) — after `config:cache` this is
// null in production. The right way is config('services.stripe.secret').
Route::get('/secret-wrong', fn () => 'env(): '.var_export(env('STRIPE_SECRET'), true));
Route::get('/secret-right', fn () => 'config(): '.var_export(config('services.stripe.secret'), true));

// Reads the legacy_note column (see the receipts migration). This is the "old
// code" for Scar 5: after a one-step migration drops legacy_note, this 500s.
Route::get('/report', function () {
    return response()->json(DB::table('receipts')->select('id', 'legacy_note')->get());
});

// A slow endpoint — hold a request open to show `docker compose up -d` dropping it
// mid-flight when there is no healthcheck / --wait (the container is recreated
// while the request is running).
Route::get('/slow', function () {
    sleep(8);
    return 'finished on version: '.config('app.version');
});

// Writes to storage/ — the PERMISSION scar (§3). php-fpm runs as the container's
// www-data; if storage/ is owned by a different UID (bind-mount from the host, or a
// volume created by root), this 500s with "Permission denied". The fix is ownership
// (Dockerfile chown + a named volume), NOT `chmod 777`.
Route::get('/store', function () {
    Storage::disk('local')->put('probe.txt', 'written by version '.config('app.version'));
    return 'stored ok → '.Storage::disk('local')->get('probe.txt');
});
