import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/errors.dart';
import 'package:typesafe_ai_sdk/src/json.dart';

class _Ticket {
  _Ticket(this.subject);
  final String subject;
  Map<String, Object?> toJson() => {'subject': subject};
}

class _NotEncodable {
  const _NotEncodable();
}

void main() {
  group('parseBody', () {
    test('returns null for an empty body', () {
      expect(parseBody('', 'application/json'), isNull);
    });

    test('parses JSON when content-type says so', () {
      expect(parseBody('{"a":1}', 'application/json'), {'a': 1});
    });

    test('parses JSON even when content-type does not say so', () {
      // Proxies misreport content-type; the JS SDK is lenient here too.
      expect(parseBody('{"a":1}', 'text/plain'), {'a': 1});
    });

    test('parses JSON when content-type is absent', () {
      expect(parseBody('[1,2]', null), [1, 2]);
    });

    test('falls back to raw text when the body is not JSON', () {
      expect(parseBody('not json', 'application/json'), 'not json');
    });
  });

  group('encodeBody', () {
    test('encodes plain JSON values', () {
      expect(encodeBody({'a': 1}, 'state'), '{"a":1}');
      expect(encodeBody('text', 'state'), '"text"');
      expect(encodeBody(null, 'state'), 'null');
    });

    test('encodes any object with a toJson method', () {
      // This is what gives free interop with json_serializable and freezed.
      expect(encodeBody(_Ticket('hi'), 'state'), '{"subject":"hi"}');
    });

    test('wraps encoding failures in TypeSafeError naming the field', () {
      expect(
        () => encodeBody(const _NotEncodable(), 'state'),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            allOf(contains('state'), contains('_NotEncodable')),
          ),
        ),
      );
    });
  });
}
