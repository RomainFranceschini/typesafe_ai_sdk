import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/logging.dart';

void main() {
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

  group('childLogger', () {
    test('puts a root parent under the SDK namespace rather than throwing', () {
      // `Logger.root.fullName` is empty, and a logger name may not start with
      // a `.`, so composing one would throw before a single request is sent.
      final child = childLogger(Logger.root, 'transport');
      expect(child.fullName, '$sdkLoggerName.transport');

      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      child.info('reaches the root listener');
      expect(records.single.message, 'reaches the root listener');
    });

    test('returns a detached parent, which can have no children', () {
      final detached = Logger.detached('detached.parent')..level = Level.ALL;
      final records = <LogRecord>[];
      final subscription = detached.onRecord.listen(records.add);
      addTearDown(subscription.cancel);

      childLogger(detached, 'transport').info('stays with the listener');
      expect(records.single.message, 'stays with the listener');
    });

    test('nests under a named parent', () {
      expect(
        childLogger(Logger('app.sdk'), 'transport').fullName,
        'app.sdk.transport',
      );
    });
  });
}
