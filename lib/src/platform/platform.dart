/// Platform-specific environment access and runtime description.
///
/// Resolves to the native implementation by default and to the web
/// implementation when `dart:js_interop` is available.
library;

export 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';
