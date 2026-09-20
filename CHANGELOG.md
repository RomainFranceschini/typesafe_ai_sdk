# Changelog

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
