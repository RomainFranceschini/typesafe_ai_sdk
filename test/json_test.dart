import 'dart:convert';

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
      expect(parseBody(const <int>[]), isNull);
    });

    test('parses a JSON object body', () {
      expect(parseBody(utf8.encode('{"a":1}')), {'a': 1});
    });

    test('parses JSON without consulting content-type', () {
      // Proxies misreport content-type; the JS SDK is lenient here too.
      expect(parseBody(utf8.encode('{"a":1}')), {'a': 1});
    });

    test('parses JSON when content-type is absent', () {
      expect(parseBody(utf8.encode('[1,2]')), [1, 2]);
    });

    test('decodes multi-byte UTF-8 straight from the bytes', () {
      expect(parseBody(utf8.encode('{"a":"caf\u00e9 \u00e9\u00e0"}')), {
        'a': 'caf\u00e9 \u00e9\u00e0',
      });
    });

    test('falls back to raw text when the body is not JSON', () {
      expect(parseBody(utf8.encode('not json')), 'not json');
    });

    test('falls back to lenient text when the body is not valid UTF-8', () {
      // A truncated multi-byte sequence fails the strict decoder that the
      // JSON path fuses; the fallback must replace it rather than throw.
      expect(parseBody(const [0xff, 0xfe]), '\uFFFD\uFFFD');
    });

    test('returns null for a body that is the literal JSON null', () {
      expect(parseBody(utf8.encode('null')), isNull);
    });
  });

  group('encodeBody', () {
    test('encodes plain JSON values to UTF-8 bytes', () {
      expect(encodeBody({'a': 1}, 'state'), utf8.encode('{"a":1}'));
      expect(encodeBody('text', 'state'), utf8.encode('"text"'));
      expect(encodeBody(null, 'state'), utf8.encode('null'));
    });

    test('encodes non-ASCII as UTF-8 rather than escapes', () {
      expect(
        encodeBody({'a': 'caf\u00e9'}, 'state'),
        utf8.encode('{"a":"caf\u00e9"}'),
      );
    });

    test('encodes any object with a toJson method', () {
      // This is what gives free interop with json_serializable and freezed.
      expect(
        encodeBody(_Ticket('hi'), 'state'),
        utf8.encode('{"subject":"hi"}'),
      );
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
