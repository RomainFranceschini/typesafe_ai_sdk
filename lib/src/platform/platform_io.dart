/// Native platform support. The only file in this package importing `dart:io`.
library;

import 'dart:io';

/// Reads a trimmed environment variable, or `null` when missing or blank.
String? readEnv(String name) {
  final value = Platform.environment[name]?.trim();
  return (value == null || value.isEmpty) ? null : value;
}

/// Whether the SDK is running in a browser page. Always false natively.
bool get isBrowser => false;

/// Describes the runtime for the `X-TypeSafe-Runtime` header.
String describeRuntime() {
  final version = Platform.version.split(' ').first;
  return 'dart/$version (${Platform.operatingSystem})';
}
