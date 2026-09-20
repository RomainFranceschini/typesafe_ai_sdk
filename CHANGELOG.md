# Changelog

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
