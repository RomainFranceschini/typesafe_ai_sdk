/// A test helper that collects records from a dedicated logger.
library;

import 'dart:async';

import 'package:logging/logging.dart';

/// Collects every record emitted by a logger created for one test.
///
/// Each capture owns a uniquely named logger, because `Logger(name)` is a
/// process-wide cache and reusing a name would let records leak between
/// tests. Call [cancel] in `tearDown`.
final class LogCapture {
  /// Starts capturing, under a logger named after [label].
  factory LogCapture(String label) {
    hierarchicalLoggingEnabled = true;
    final logger = Logger('test.$label.${_counter++}')..level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = logger.onRecord.listen(records.add);
    return LogCapture._(logger, records, subscription);
  }

  LogCapture._(this.logger, this.records, this._subscription);

  static int _counter = 0;

  /// The logger to hand to the code under test.
  final Logger logger;

  /// Every record emitted so far, in order.
  final List<LogRecord> records;

  final StreamSubscription<LogRecord> _subscription;

  /// The messages of records at [level].
  List<String> messagesAt(Level level) => records
      .where((record) => record.level == level)
      .map((record) => record.message)
      .toList();

  /// Stops capturing.
  Future<void> cancel() => _subscription.cancel();
}
