/// The SDK's logger hierarchy and header redaction.
library;

import 'package:logging/logging.dart';

/// The name of the SDK's root logger.
///
/// Every record the SDK emits comes from this logger or a child of it, so
/// listening under this name captures all of them.
const String sdkLoggerName = 'typesafe_ai_sdk';

/// The logger used when the caller supplies none.
Logger get defaultLogger => Logger(sdkLoggerName);

/// A child of [parent] named [suffix], so records can be filtered by
/// subsystem.
///
/// [Logger.root] has an empty name, and a name may not start with a `.`, so a
/// root parent yields a child under the SDK's own namespace, which still
/// propagates to the root. A detached logger can have no children at all —
/// `Logger('$sdkLoggerName.transport')` would attach to the global hierarchy
/// instead, and the detached listener would never see a record — so a
/// detached parent is returned as-is.
Logger childLogger(Logger parent, String suffix) {
  final fullName = parent.fullName;
  if (fullName.isEmpty) return Logger('$sdkLoggerName.$suffix');
  if (parent.parent == null) return parent;
  return Logger('$fullName.$suffix');
}

/// Hoisted: [_redactKey] runs once per credential header per logged request.
final RegExp _whitespace = RegExp(r'\s');

const Set<String> _keyHeaders = {
  'authorization',
  'proxy-authorization',
  'x-api-key',
};

const Set<String> _opaqueHeaders = {'cookie', 'set-cookie'};

/// Masks a credential, keeping its scheme and the last four characters of
/// secrets longer than eight.
String _redactKey(String value) {
  final separator = value.indexOf(_whitespace);
  final scheme = separator == -1 ? null : value.substring(0, separator);
  final secret = separator == -1
      ? value
      : value.substring(separator + 1).trimLeft();
  final tail = secret.length > 8 ? secret.substring(secret.length - 4) : '';
  return scheme == null ? '***$tail' : '$scheme ***$tail';
}

/// Copies [headers] with known credential values masked.
///
/// Bodies are not redacted, matching the JS SDK. Do not log bodies at
/// [Level.FINE] in an environment where the transcript is untrusted.
Map<String, String> redactHeaders(Map<String, String> headers) {
  return headers.map((name, value) {
    final lower = name.toLowerCase();
    if (_keyHeaders.contains(lower)) return MapEntry(name, _redactKey(value));
    if (_opaqueHeaders.contains(lower)) return MapEntry(name, '***');
    return MapEntry(name, value);
  });
}
