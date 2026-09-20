# Changelog

## Unreleased

Breaking: logging now goes through [`package:logging`][logging] instead of the
SDK's own logger types.

- Removed `LogLevel`, the `Logger` interface, and `DeveloperLogger`
- Removed the `logLevel` client option and the `TYPESAFE_LOG_LEVEL`
  environment variable; set `Logger.root.level` in your application instead
- `TypeSafeClient(logger:)` now takes a `package:logging` `Logger`, defaulting
  to `Logger('typesafe_ai_sdk')`, with `.transport` and `.response` children
- Added the exported `sdkLoggerName` constant
- The SDK no longer writes to `dart:developer` on its own: it emits nothing
  until the application attaches a handler to `Logger.root.onRecord`
- Level mapping for existing users: `debug` is now `Level.FINE`, `warn` is
  `Level.WARNING`, and `error` is `Level.SEVERE`

[logging]: https://pub.dev/packages/logging

Breaking: the `ApiError` hierarchy now takes named constructor parameters.

- `ApiError(status, body, headers)` and each subclass become
  `ApiError(statusCode: ..., body: ..., headers: ...)`; `ApiError.fromResponse`
  is unchanged
- `Question.checkType` is no longer a member of the sealed `Question` class
- Answers, `Usage`, and `ModelCard` now implement `==`, `hashCode`, and
  `toString`, so they compare by value
- `RetryPolicy` gained `retriesStatus` and `delayFor`, replacing the
  library-private `isRetryableStatus` and `retryDelay` free functions
- A request body is now encoded once instead of twice; an encoding failure
  names the offending value rather than assuming it came from `state`
- Request latency is measured with `Stopwatch` rather than wall-clock
  subtraction, so a clock adjustment can no longer report a negative duration
- Added a direct dependency on `package:collection` for deep equality

Fixes from a full-codebase review.

- `TypeSafeClient(logger: Logger.root)` no longer throws: a root parent now
  yields children under `typesafe_ai_sdk`, and a `Logger.detached` parent is
  used directly rather than silently rerouting records to the global hierarchy
- An oversized `Retry-After` or `retry-after-ms` value is clamped instead of
  overflowing into a negative delay that retried with no backoff at all;
  exponential backoff is likewise capped past attempt 63
- A plain-text error body is truncated in `ApiError.message` like a structured
  one, instead of reaching `toString()` and the logs in full
- An error response body is scrubbed of the API key before it is logged or
  folded into `ApiError`, in case the server echoes the request back
- `baseUrl` may no longer carry a query string or fragment, which would have
  swallowed the request path and sent requests to the site root
- An explicitly passed `apiKey` is trimmed, matching keys read from the
  environment; an untrimmed one failed later as a retried connection error
- A response with a missing or non-object `answers` field now raises
  `ApiResponseValidationError`, like a missing `model`, instead of surfacing
  later as an `ArgumentError` from `SystemOneResponse.get`
- `ChoiceAnswer.probabilities` and `ScoreAnswer.legend`/`probabilities` are
  unmodifiable, like every other collection the SDK hands out
- `avoid_print` is now enforced in `lib/`; per-request `INFO` logs are built
  lazily, and a request that never connects logs its terminal outcome

## 0.1.0

Initial release. An unofficial Dart port of the TypeSafe AI JavaScript SDK
v0.6.0.

- `TypeSafeClient.systemOne` with `Noul`, `Choice`, and `Score` questions
- Statically typed answers via `SystemOneResponse.get`, with enum-typed
  choice labels and score levels
- `client.models.list()`
- Retry policy with jittered backoff and `Retry-After` support
- Typed error hierarchy with request IDs
- Leveled logging with credential redaction
- Native and web support
