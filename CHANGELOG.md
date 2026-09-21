# Changelog

## 0.2.0

- **Breaking** Requires `package:http` `^1.6.0`, for request aborting and the
  web response-cancellation fix it depends on
- Response bodies are bounded by the new `maxResponseBodyBytes` option
  (10 MiB by default): a larger successful response raises
  `ApiResponseValidationError`, while an error response is truncated at the
  limit so its status, request ID and `Retry-After` survive and a retryable
  status is still retried
- `TypeSafeClient.maxResponseBodyBytes` and `defaultMaxResponseBodyBytes` are
  part of the public API
- Timeouts abort the underlying request, so an abandoned attempt no longer
  leaves a download in flight
- A `TimeoutException` raised by a custom `http.Client` maps to
  `ApiTimeoutError` again, rather than being retried as a connection error
- A non-positive per-call `timeout` is rejected, matching the validation
  already applied to the client-wide one
- A request that ends on a terminal SDK error closes out its log transcript
  instead of going silent after the request line

## 0.1.0

Initial release. An unofficial Dart port of the TypeSafe AI JavaScript SDK
v0.6.0.

- `TypeSafeClient.systemOne` with `Noul`, `Choice`, and `Score` questions
- Statically typed answers via `SystemOneResponse.get`, with enum-typed
  choice labels and score levels
- `client.models.list()`
- Retry policy with jittered backoff, `Retry-After` support, and clamped
  delays that never overflow into an unbounded retry loop
- Typed error hierarchy with request IDs, named constructor parameters, and
  truncated, credential-scrubbed bodies
- Value equality (`==`, `hashCode`, `toString`) on answers, `Usage`, and
  `ModelCard`, and unmodifiable collections throughout the public API
- Strict response validation: a malformed payload raises
  `ApiResponseValidationError` rather than surfacing later as an
  `ArgumentError`
- Logging through [`package:logging`][logging] under `sdkLoggerName`, with
  credential redaction; the SDK emits nothing until the application attaches a
  handler to `Logger.root.onRecord`
- Native and web support

[logging]: https://pub.dev/packages/logging
