/// Web platform support. Environment variables do not exist in a browser.
library;

/// Always `null`: browsers have no environment variables.
///
/// On web the API key must be passed explicitly to `TypeSafeClient`.
String? readEnv(String name) => null;

/// Whether the SDK is running in a browser page. Always true on web.
bool get isBrowser => true;

/// Describes the runtime for the `X-TypeSafe-Runtime` header.
String describeRuntime() => 'browser';
