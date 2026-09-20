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
}
