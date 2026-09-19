/// Log levels, the default sink, level filtering, and header redaction.
library;

import 'dart:developer' as developer;

import 'errors.dart';

/// Log verbosity. [LogLevel.off] disables logging.
enum LogLevel {
  /// Requests, headers, and bodies.
  debug,

  /// Request summaries.
  info,

  /// Warnings only.
  warn,

  /// Errors only.
  error,

  /// Nothing.
  off,
}

/// A sink for SDK log records.
abstract interface class Logger {
  /// Logs a debug-level message.
  void debug(String message, [Object? data]);

  /// Logs an info-level message.
  void info(String message, [Object? data]);

  /// Logs a warning-level message.
  void warn(String message, [Object? data]);

  /// Logs an error-level message.
  void error(String message, [Object? data]);
}

const String _prefix = '[typesafe_ai_sdk]';

/// The default logger, writing through `dart:developer`.
///
/// `dart:developer` works on both native and web, and avoids `print`.
class DeveloperLogger implements Logger {
  /// Creates the default logger.
  const DeveloperLogger();

  void _emit(String level, String message, Object? data) {
    final suffix = data == null ? '' : ' $data';
    developer.log('$message$suffix', name: '$_prefix $level');
  }

  @override
  void debug(String message, [Object? data]) => _emit('debug', message, data);

  @override
  void info(String message, [Object? data]) => _emit('info', message, data);

  @override
  void warn(String message, [Object? data]) => _emit('warn', message, data);

  @override
  void error(String message, [Object? data]) => _emit('error', message, data);
}

class _LeveledLogger implements Logger {
  _LeveledLogger(this._sink, this._level);

  final Logger _sink;
  final LogLevel _level;

  bool _enabled(LogLevel at) => at.index >= _level.index;

  @override
  void debug(String message, [Object? data]) {
    if (_enabled(LogLevel.debug)) _sink.debug(message, data);
  }

  @override
  void info(String message, [Object? data]) {
    if (_enabled(LogLevel.info)) _sink.info(message, data);
  }

  @override
  void warn(String message, [Object? data]) {
    if (_enabled(LogLevel.warn)) _sink.warn(message, data);
  }

  @override
  void error(String message, [Object? data]) {
    if (_enabled(LogLevel.error)) _sink.error(message, data);
  }
}

/// Wraps [sink] so it only receives records at [level] or above.
Logger withLevel(Logger sink, LogLevel level) => _LeveledLogger(sink, level);

/// Parses a log level name, naming [source] in the error when it is unknown.
LogLevel parseLogLevel(String value, String source) {
  for (final level in LogLevel.values) {
    if (level.name == value) return level;
  }
  final names = LogLevel.values.map((level) => level.name).join(', ');
  throw TypeSafeError(
    'Invalid log level "$value" from $source. Expected one of: $names.',
  );
}

const Set<String> _keyHeaders = {
  'authorization',
  'proxy-authorization',
  'x-api-key',
};

const Set<String> _opaqueHeaders = {'cookie', 'set-cookie'};

/// Masks a credential, keeping its scheme and the last four characters of
/// secrets longer than eight.
String _redactKey(String value) {
  final separator = value.indexOf(RegExp(r'\s'));
  final scheme = separator == -1 ? null : value.substring(0, separator);
  final secret = separator == -1
      ? value
      : value.substring(separator + 1).trimLeft();
  final tail = secret.length > 8 ? secret.substring(secret.length - 4) : '';
  return scheme == null ? '***$tail' : '$scheme ***$tail';
}

/// Copies [headers] with known credential values masked.
///
/// Bodies are not redacted, matching the JS SDK. Do not log bodies at `debug`
/// in an environment where the transcript is untrusted.
Map<String, String> redactHeaders(Map<String, String> headers) {
  return headers.map((name, value) {
    final lower = name.toLowerCase();
    if (_keyHeaders.contains(lower)) return MapEntry(name, _redactKey(value));
    if (_opaqueHeaders.contains(lower)) return MapEntry(name, '***');
    return MapEntry(name, value);
  });
}
