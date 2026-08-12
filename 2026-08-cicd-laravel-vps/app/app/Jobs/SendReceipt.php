<?php

namespace App\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Log;

/*
| A trivial queued job whose ONLY purpose is to log which APP_VERSION handled it.
| After a deploy WITHOUT `queue:restart`, a long-lived worker keeps the OLD code
| in memory, so this line logs the OLD version even though the web tier shows the
| new one — the "worker still runs old code" scar. After queue:restart (Supervisor
| respawns the worker), the same job logs the NEW version.
*/
class SendReceipt implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public function handle(): void
    {
        Log::info('SendReceipt processed by version: '.config('app.version'));
    }
}
