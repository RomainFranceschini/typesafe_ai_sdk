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
