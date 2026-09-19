import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/errors.dart';
import 'package:typesafe_ai_sdk/src/logging.dart';

class _RecordingLogger implements Logger {
  final List<String> records = [];
  @override
  void debug(String message, [Object? data]) => records.add('debug:$message');
  @override
  void info(String message, [Object? data]) => records.add('info:$message');
  @override
  void warn(String message, [Object? data]) => records.add('warn:$message');
  @override
  void error(String message, [Object? data]) => records.add('error:$message');
}

void _emitAll(Logger logger) {
  logger.debug('d');
  logger.info('i');
  logger.warn('w');
  logger.error('e');
}

void main() {
  group('withLevel', () {
    test('warn passes warn and error only', () {
      final sink = _RecordingLogger();
      _emitAll(withLevel(sink, LogLevel.warn));
      expect(sink.records, ['warn:w', 'error:e']);
    });

    test('debug passes everything', () {
      final sink = _RecordingLogger();
      _emitAll(withLevel(sink, LogLevel.debug));
      expect(sink.records, ['debug:d', 'info:i', 'warn:w', 'error:e']);
    });

    test('off passes nothing', () {
      final sink = _RecordingLogger();
      _emitAll(withLevel(sink, LogLevel.off));
      expect(sink.records, isEmpty);
    });
  });

  group('parseLogLevel', () {
    test('accepts every level name', () {
      expect(parseLogLevel('debug', 'test'), LogLevel.debug);
      expect(parseLogLevel('off', 'test'), LogLevel.off);
    });

    test('rejects an unknown level, naming the source', () {
      expect(
        () => parseLogLevel('loud', 'TYPESAFE_LOG_LEVEL'),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            allOf(contains('loud'), contains('TYPESAFE_LOG_LEVEL')),
          ),
        ),
      );
    });
  });

  group('redactHeaders', () {
    test('keeps the scheme and last four characters of a long secret', () {
      final redacted = redactHeaders({
        'authorization': 'Bearer sk-abcdefghijkl',
      });
      expect(redacted['authorization'], 'Bearer ***ijkl');
    });

    test('reveals nothing from a short secret', () {
      final redacted = redactHeaders({'authorization': 'Bearer short'});
      expect(redacted['authorization'], 'Bearer ***');
    });

    test('redacts a schemeless key header', () {
      final redacted = redactHeaders({'x-api-key': 'sk-abcdefghijkl'});
      expect(redacted['x-api-key'], '***ijkl');
    });

    test('fully masks cookies', () {
      expect(redactHeaders({'cookie': 'session=abc'})['cookie'], '***');
      expect(redactHeaders({'set-cookie': 'session=abc'})['set-cookie'], '***');
    });

    test('leaves ordinary headers untouched', () {
      final redacted = redactHeaders({'content-type': 'application/json'});
      expect(redacted['content-type'], 'application/json');
    });

    test('matches header names case-insensitively', () {
      final redacted = redactHeaders({
        'Authorization': 'Bearer sk-abcdefghijkl',
      });
      expect(redacted['Authorization'], 'Bearer ***ijkl');
    });
  });
}
