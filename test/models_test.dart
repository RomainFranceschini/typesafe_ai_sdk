import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/errors.dart';
import 'package:typesafe_ai_sdk/src/resources/models.dart';
import 'package:typesafe_ai_sdk/src/retry.dart';
import 'package:typesafe_ai_sdk/src/transport.dart';

/// A logger with no listener, so records go nowhere.
Logger _silentLogger() => Logger('test.models.silent');

Models modelsFor(String responseBody, {int status = 200}) {
  final transport = Transport(
    httpClient: MockClient((request) async {
      expect(request.url.path, '/v1/models');
      expect(request.method, 'GET');
      return http.Response(
        responseBody,
        status,
        headers: {'content-type': 'application/json'},
      );
    }),
    baseUrl: 'https://api.example',
    apiKey: 'k',
    defaultHeaders: const {},
    logger: _silentLogger(),
    retry: RetryPolicy().copyWith(maxRetries: 0),
    timeout: const Duration(seconds: 5),
    sleep: (duration) async {},
    runtime: 'dart/test (test)',
    browser: false,
  );
  return Models(transport);
}

void main() {
  test('lists models', () async {
    final models = await modelsFor(
      jsonEncode({
        'models': [
          {
            'name': 'jev-latest',
            'description': 'The latest model',
            'release_date': '2026-09-01',
          },
        ],
      }),
    ).list();

    expect(models, hasLength(1));
    expect(models.single.name, 'jev-latest');
    expect(models.single.description, 'The latest model');
    expect(models.single.releaseDate, '2026-09-01');
  });

  test('returns an empty list when the API sends none', () async {
    expect(
      await modelsFor(jsonEncode({'models': <Object?>[]})).list(),
      isEmpty,
    );
  });

  test('rejects a response without a models array', () async {
    await expectLater(
      modelsFor(jsonEncode({'data': <Object?>[]})).list(),
      throwsA(
        isA<ApiResponseValidationError>().having(
          (e) => e.message,
          'message',
          contains('{ models: [...] }'),
        ),
      ),
    );
  });

  test('rejects a malformed model entry', () async {
    await expectLater(
      modelsFor(
        jsonEncode({
          'models': [
            {'name': 'x'},
          ],
        }),
      ).list(),
      throwsA(isA<ApiResponseValidationError>()),
    );
  });

  test('propagates API errors', () async {
    await expectLater(
      modelsFor('nope', status: 401).list(),
      throwsA(isA<AuthenticationError>()),
    );
  });

  test('handles a 200 response with a malformed Content-Type header', () async {
    final responseBody = jsonEncode({
      'models': [
        {
          'name': 'jev-latest',
          'description': 'The latest model',
          'release_date': '2026-09-01',
        },
      ],
    });
    final transport = Transport(
      httpClient: MockClient((request) async {
        return http.Response.bytes(
          utf8.encode(responseBody),
          200,
          headers: {'content-type': 'application/json, text/html'},
        );
      }),
      baseUrl: 'https://api.example',
      apiKey: 'k',
      defaultHeaders: const {},
      logger: _silentLogger(),
      retry: RetryPolicy().copyWith(maxRetries: 0),
      timeout: const Duration(seconds: 5),
      sleep: (duration) async {},
      runtime: 'dart/test (test)',
      browser: false,
    );
    final models = Models(transport);
    final result = await models.list();
    expect(result, hasLength(1));
    expect(result.single.name, 'jev-latest');
  });
}
