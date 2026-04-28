<?php

/*
|--------------------------------------------------------------------------
| Web Routes
|--------------------------------------------------------------------------
|
| Replaces the default routes/web.php in a freshly-scaffolded Laravel
| project. Defines the routes required by the assignment plus a tiny
| informational endpoint that proves the request really did land in a
| Kubernetes pod.
|
|   GET /        -> Renders the welcome view. The view contains the
|                   exact required string "Laravel Kubernetes Deployment
|                   Test" prominently, plus pod / env metadata for
|                   visual proof.
|
|   GET /health  -> 200 OK with JSON. No DB, no cache, no session,
|                   so liveness / readiness probes stay cheap.
|
|   GET /info    -> JSON dump of selected env + pod info, useful when
|                   debugging from curl. Not in the assignment, but
|                   harmless and helpful during the demo.
|
*/

use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome', [
        'pod'        => gethostname(),
        'appName'    => config('app.name'),
        'appEnv'     => config('app.env'),
        'phpVersion' => PHP_VERSION,
        'laravel'    => app()->version(),
        'now'        => now()->toIso8601String(),
    ]);
});

Route::get('/health', function () {
    return response()->json([
        'status' => 'ok',
        'pod'    => gethostname(),
        'app'    => config('app.name'),
        'env'    => config('app.env'),
        'time'   => now()->toIso8601String(),
    ], 200);
});

Route::get('/info', function () {
    return response()->json([
        'pod'         => gethostname(),
        'app'         => config('app.name'),
        'env'         => config('app.env'),
        'php'         => PHP_VERSION,
        'laravel'     => app()->version(),
        'request_ip'  => request()->ip(),
        'request_uri' => request()->fullUrl(),
        'time'        => now()->toIso8601String(),
    ], 200);
});
