<?php

/*
| Third-party service credentials. THIS is the only correct place to call env():
| config files are read at `config:cache` time, so config('services.stripe.secret')
| keeps working in production. Calling env('STRIPE_SECRET') from a controller/route
| returns null once config is cached — see routes/web.php (/secret-wrong vs /secret-right).
*/

return [
    'stripe' => [
        'secret' => env('STRIPE_SECRET'),
    ],
];
