<?php

// Smoke test for the opentelemetry extension, run with it loaded explicitly (Flock never loads it
// by default). Flock only uses its hook(): a pre hook that replaces an argument and a post hook
// that replaces the return value, on a class declared after the hooks (like the app's classes).
// Prints "hook ok <version>" or what went wrong; exits 1 on failure.

if (!function_exists('OpenTelemetry\Instrumentation\hook')) {
    echo "hook() missing\n";
    exit(1);
}

\OpenTelemetry\Instrumentation\hook('LaterClass', 'greet',
    pre: static fn ($object, array $params): array => [0 => $params[0].' (pre)'],
    post: static fn ($object, array $params, $return): string => $return.' (post)',
);

// Declared at run time, after the hooks: a top-level class would be bound at compile time.
if (true) {
    class LaterClass
    {
        public function greet(string $name): string
        {
            return "hello $name";
        }
    }
}

$got = (new LaterClass())->greet('flock');
if ($got !== 'hello flock (pre) (post)') {
    echo "hooks did not fire: $got\n";
    exit(1);
}
echo 'hook ok ', phpversion('opentelemetry'), "\n";
