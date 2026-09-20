import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

enum _Tone { calm, frustrated, angry }

class _Unencodable {
  @override
  String toString() => 'unencodable value';
}

class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._handler);
  final MockClient _handler;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler.send(request);

  @override
  void close() => closed = true;
}

String _systemOneBody() => jsonEncode({
  'model': 'jev-latest',
  'usage': {'input_tokens': 10, 'output_tokens': 2},
  'answers': {
    'isBilling': {'type': 'noul', 'noul': 0.9},
    'tone': {
      'type': 'choice',
      'choice': 'frustrated',
      'confidence': 0.7,
      'probabilities': {'calm': 0.1, 'frustrated': 0.7, 'angry': 0.2},
    },
  },
});

void main() {
  late List<http.Request> requests;

  TypeSafeClient clientFor(
    Future<http.Response> Function(http.Request) handler, {
    String? defaultModel,
    http.Client? httpClient,
  }) {
    requests = [];
    return TypeSafeClient(
      apiKey: 'sk-test',
      baseUrl: 'https://api.example',
      defaultModel: defaultModel,
      httpClient:
          httpClient ??
          MockClient((request) async {
            requests.add(request);
            return handler(request);
          }),
    );
  }

  test('sends state, questions, and the default model', () async {
    final client = clientFor(
      (_) async => http.Response(
        _systemOneBody(),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final isBilling = Noul(instructions: 'Is this billing?');
    final tone = Choice({
      _Tone.calm: null,
      _Tone.frustrated: null,
      _Tone.angry: null,
    }, instructions: 'Tone?');

    await client.systemOne(
      state: {'document': 'I was charged twice.'},
      questions: {'isBilling': isBilling, 'tone': tone},
    );

    final sent = jsonDecode(requests.single.body) as Map<String, Object?>;
    expect(sent['model'], 'jev-latest');
    expect(sent['state'], {'document': 'I was charged twice.'});
    final questions = sent['questions']! as Map<String, Object?>;
    expect((questions['isBilling']! as Map)['type'], 'noul');
    expect((questions['tone']! as Map)['criteria'], {
      'calm': null,
      'frustrated': null,
      'angry': null,
    });
    expect(requests.single.url.toString(), 'https://api.example/v1/systemone');
    client.close();
  });

  test('returns typed answers through get', () async {
    final client = clientFor(
      (_) async => http.Response(
        _systemOneBody(),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final isBilling = Noul(instructions: 'Is this billing?');
    final tone = Choice({
      _Tone.calm: null,
      _Tone.frustrated: null,
      _Tone.angry: null,
    });

    final response = await client.systemOne(
      state: 'text',
      questions: {'isBilling': isBilling, 'tone': tone},
    );

    expect(response.get(isBilling).noul, 0.9);
    expect(response.get(tone).choice, _Tone.frustrated);
    expect(response.model, 'jev-latest');
    expect(response.usage.inputTokens, 10);
    expect(response.httpResponse.statusCode, 200);
    client.close();
  });

  test('a per-request model overrides the default', () async {
    final client = clientFor(
      (_) async => http.Response(
        _systemOneBody(),
        200,
        headers: {'content-type': 'application/json'},
      ),
      defaultModel: 'jev-1',
    );
    await client.systemOne(
      state: 'x',
      questions: {'isBilling': Noul()},
      model: 'jev-2',
    );
    expect((jsonDecode(requests.single.body) as Map)['model'], 'jev-2');
    client.close();
  });

  test('rejects an empty question set before any request', () async {
    final client = clientFor((_) async => http.Response('{}', 200));
    await expectLater(
      client.systemOne(state: 'x', questions: {}),
      throwsA(
        isA<TypeSafeError>().having(
          (e) => e.message,
          'message',
          contains('At least one'),
        ),
      ),
    );
    expect(requests, isEmpty);
    client.close();
  });

  test('rejects state that cannot be encoded, naming the value', () async {
    final client = clientFor((_) async => http.Response('{}', 200));
    await expectLater(
      client.systemOne(state: _Unencodable(), questions: {'a': Noul()}),
      throwsA(
        isA<TypeSafeError>().having(
          (e) => e.message,
          'message',
          allOf(contains('_Unencodable'), contains('not JSON-encodable')),
        ),
      ),
    );
    expect(requests, isEmpty);
    client.close();
  });

  test('rejects unencodable instructions, not just state', () async {
    // The body is encoded once, so the error names the offending value rather
    // than guessing at a field: `instructions` and criteria descriptions take
    // arbitrary caller objects just as `state` does.
    final client = clientFor((_) async => http.Response('{}', 200));
    await expectLater(
      client.systemOne(
        state: 'fine',
        questions: {'a': Noul(instructions: _Unencodable())},
      ),
      throwsA(
        isA<TypeSafeError>().having(
          (e) => e.message,
          'message',
          allOf(contains('_Unencodable'), contains('not JSON-encodable')),
        ),
      ),
    );
    expect(requests, isEmpty);
    client.close();
  });

  test('handles a 200 response with a malformed Content-Type header', () async {
    final client = clientFor(
      (_) async => http.Response.bytes(
        utf8.encode(_systemOneBody()),
        200,
        headers: {'content-type': 'application/json, text/html'},
      ),
    );

    final isBilling = Noul(instructions: 'Is this billing?');
    final response = await client.systemOne(
      state: 'x',
      questions: {'isBilling': isBilling},
    );

    expect(response.get(isBilling).noul, 0.9);
    client.close();
  });

  group('http client ownership', () {
    test('does not close an injected client', () {
      final injected = _TrackingClient(
        MockClient((_) async {
          return http.Response('{}', 200);
        }),
      );
      TypeSafeClient(apiKey: 'k', httpClient: injected).close();
      expect(injected.closed, isFalse);
    });
  });

  test('exposes resolved configuration', () {
    final client = TypeSafeClient(
      apiKey: 'k',
      baseUrl: 'https://api.example/',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    expect(client.baseUrl, 'https://api.example');
    expect(client.defaultModel, 'jev-latest');
    expect(client.timeout, const Duration(seconds: 10));
    client.close();
  });
}
