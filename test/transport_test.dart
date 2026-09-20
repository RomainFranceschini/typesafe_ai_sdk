import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/errors.dart';
import 'package:typesafe_ai_sdk/src/retry.dart';
import 'package:typesafe_ai_sdk/src/transport.dart';

import 'support/log_capture.dart';

/// A logger with no listener, so records go nowhere.
Logger _silentLogger() => Logger('test.transport.silent');

class _ZeroRandom implements Random {
  @override
  double nextDouble() => 0;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

void main() {
  late List<http.Request> requests;
  late List<Duration> slept;

  setUp(() {
    requests = [];
    slept = [];
  });

  Transport transportFor(
    Future<http.Response> Function(http.Request request) handler, {
    RetryPolicy? retry,
    Duration timeout = const Duration(seconds: 5),
    Map<String, String> defaultHeaders = const {},
    bool browser = false,
  }) {
    return Transport(
      httpClient: MockClient((request) async {
        requests.add(request);
        return handler(request);
      }),
      baseUrl: 'https://api.example',
      apiKey: 'sk-secret-key-value',
      defaultHeaders: defaultHeaders,
      logger: _silentLogger(),
      retry: retry ?? RetryPolicy(),
      timeout: timeout,
      random: _ZeroRandom(),
      sleep: (duration) async => slept.add(duration),
      runtime: 'dart/test (test)',
      browser: browser,
    );
  }

  group('headers', () {
    test('sends auth, accept, sdk, and runtime headers', () async {
      final transport = transportFor((_) async => http.Response('{}', 200));
      await transport.send('GET', '/v1/models');

      final headers = requests.single.headers;
      expect(headers['authorization'], 'Bearer sk-secret-key-value');
      expect(headers['accept'], 'application/json');
      expect(headers['x-typesafe-sdk'], startsWith('typesafe-ai-sdk-dart/'));
      expect(headers['x-typesafe-runtime'], 'dart/test (test)');
      expect(headers['user-agent'], startsWith('typesafe-ai-sdk-dart/'));
    });

    test('omits user-agent in a browser, where it is forbidden', () async {
      final transport = transportFor(
        (_) async => http.Response('{}', 200),
        browser: true,
      );
      await transport.send('GET', '/v1/models');
      expect(requests.single.headers.containsKey('user-agent'), isFalse);
      expect(requests.single.headers['x-typesafe-sdk'], isNotNull);
    });

    test('removes caller-supplied user-agent in a browser', () async {
      final transport = transportFor(
        (_) async => http.Response('{}', 200),
        browser: true,
      );
      await transport.send(
        'GET',
        '/v1/models',
        headers: {'user-agent': 'custom/1.0'},
      );
      expect(requests.single.headers.containsKey('user-agent'), isFalse);
    });

    test('caller headers cannot clobber authorization', () async {
      final transport = transportFor((_) async => http.Response('{}', 200));
      await transport.send(
        'GET',
        '/v1/models',
        headers: {'Authorization': 'Bearer attacker'},
      );
      expect(
        requests.single.headers['authorization'],
        'Bearer sk-secret-key-value',
      );
    });

    test('merges default headers and lets per-call headers win', () async {
      final transport = transportFor(
        (_) async => http.Response('{}', 200),
        defaultHeaders: {'x-tenant': 'default', 'x-keep': 'yes'},
      );
      await transport.send(
        'GET',
        '/v1/models',
        headers: {'x-tenant': 'override'},
      );
      expect(requests.single.headers['x-tenant'], 'override');
      expect(requests.single.headers['x-keep'], 'yes');
    });

    test('sets content-type only when there is a body', () async {
      final transport = transportFor((_) async => http.Response('{}', 200));
      await transport.send('GET', '/v1/models');
      expect(requests.single.headers.containsKey('content-type'), isFalse);

      await transport.send('POST', '/v1/systemone', body: {'a': 1});
      expect(requests.last.headers['content-type'], 'application/json');
      expect(requests.last.body, '{"a":1}');
    });
  });

  group('retries', () {
    test('retries a 500 and returns the eventual success', () async {
      var calls = 0;
      final transport = transportFor((_) async {
        calls++;
        return calls < 3
            ? http.Response('fail', 500)
            : http.Response('{"ok":true}', 200);
      });

      final response = await transport.send('GET', '/v1/models');
      expect(response.statusCode, 200);
      expect(calls, 3);
      expect(slept, [
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 1000),
      ]);
    });

    test('adds a retry-count header from the second attempt onward', () async {
      var calls = 0;
      final transport = transportFor((_) async {
        calls++;
        return calls < 2 ? http.Response('x', 500) : http.Response('{}', 200);
      });
      await transport.send('GET', '/v1/models');

      expect(
        requests[0].headers.containsKey('x-typesafe-retry-count'),
        isFalse,
      );
      expect(requests[1].headers['x-typesafe-retry-count'], '1');
    });

    test('gives up after maxRetries and throws the last error', () async {
      final transport = transportFor((_) async => http.Response('nope', 503));
      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(
          isA<InternalServerError>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
      expect(requests, hasLength(3)); // initial attempt plus two retries
    });

    test('does not retry a 400', () async {
      final transport = transportFor((_) async => http.Response('bad', 400));
      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(isA<BadRequestError>()),
      );
      expect(requests, hasLength(1));
    });

    test('honors a per-call retry override', () async {
      final transport = transportFor((_) async => http.Response('x', 500));
      await expectLater(
        transport.send(
          'GET',
          '/v1/models',
          retry: RetryPolicy().copyWith(maxRetries: 0),
        ),
        throwsA(isA<InternalServerError>()),
      );
      expect(requests, hasLength(1));
    });

    test('uses a server Retry-After delay', () async {
      var calls = 0;
      final transport = transportFor((_) async {
        calls++;
        return calls < 2
            ? http.Response('x', 429, headers: {'retry-after': '2'})
            : http.Response('{}', 200);
      });
      await transport.send('GET', '/v1/models');
      expect(slept, [const Duration(seconds: 2)]);
    });

    test('retries connection errors', () async {
      var calls = 0;
      final transport = transportFor((_) async {
        calls++;
        if (calls < 2) throw http.ClientException('socket died');
        return http.Response('{}', 200);
      });
      final response = await transport.send('GET', '/v1/models');
      expect(response.statusCode, 200);
      expect(calls, 2);
    });

    test('does not retry connection errors when disabled', () async {
      final transport = transportFor(
        (_) async => throw http.ClientException('socket died'),
        retry: RetryPolicy().copyWith(retryConnectionErrors: false),
      );
      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(isA<ApiConnectionError>()),
      );
      expect(requests, hasLength(1));
    });
  });

  group('timeouts', () {
    test(
      'throws ApiTimeoutError when an attempt exceeds the timeout',
      () async {
        final transport = transportFor(
          (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return http.Response('{}', 200);
          },
          timeout: const Duration(milliseconds: 50),
          retry: RetryPolicy().copyWith(maxRetries: 0),
        );
        await expectLater(
          transport.send('GET', '/v1/models'),
          throwsA(
            isA<ApiTimeoutError>().having(
              (e) => e.timeout,
              'timeout',
              const Duration(milliseconds: 50),
            ),
          ),
        );
      },
    );
  });

  group('errors', () {
    test('maps the status and extracts the message and request ID', () async {
      final transport = transportFor(
        (_) async => http.Response(
          jsonEncode({'error': 'key is bad'}),
          401,
          headers: {
            'content-type': 'application/json',
            'x-typesafe-request-id': 'req_42',
          },
        ),
      );
      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(
          isA<AuthenticationError>()
              .having((e) => e.message, 'message', '401 key is bad')
              .having((e) => e.requestId, 'requestId', 'req_42'),
        ),
      );
    });

    test('maps a non-2xx response with a malformed Content-Type instead of '
        'throwing a FormatException', () async {
      // A duplicated Content-Type response header is joined by HTTP clients
      // into one comma-separated value, which `http.Response.body` cannot
      // parse and throws a FormatException on. `Transport` reads `bodyBytes`
      // and never consults the header, so the error path produces an ApiError;
      // this guards against a regression back to the `body` getter.
      //
      // Built with `Response.bytes` rather than the `Response(String, ...)`
      // constructor: the latter parses Content-Type eagerly (to choose an
      // encoding) at construction time, which would throw here in the test
      // handler itself.
      final transport = transportFor(
        (_) async => http.Response.bytes(
          utf8.encode('not actually json'),
          500,
          headers: {'content-type': 'application/json, text/html'},
        ),
      );
      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(isA<InternalServerError>()),
      );
    });

    test('trims stray whitespace from header names', () async {
      final transport = transportFor((_) async => http.Response('{}', 200));
      await transport.send(
        'GET',
        '/v1/models',
        headers: {' x-tenant ': 'acme'},
      );
      expect(requests.single.headers['x-tenant'], 'acme');
      expect(requests.single.headers.containsKey(' x-tenant '), isFalse);
    });

    test('rejects a path that does not start with "/"', () async {
      final transport = transportFor((_) async => http.Response('{}', 200));
      await expectLater(
        transport.send('GET', '@evil.example/v1'),
        throwsA(isA<TypeSafeError>()),
      );
      expect(requests, isEmpty);
    });
  });

  test('never logs the API key, even at debug level', () async {
    final capture = LogCapture('transport');
    addTearDown(capture.cancel);
    final transport = Transport(
      httpClient: MockClient((_) async => http.Response('{}', 200)),
      baseUrl: 'https://api.example',
      apiKey: 'sk-secret-key-value',
      defaultHeaders: const {},
      logger: capture.logger,
      retry: RetryPolicy(),
      timeout: const Duration(seconds: 5),
      random: _ZeroRandom(),
      sleep: (duration) async {},
      runtime: 'dart/test (test)',
      browser: false,
    );
    await transport.send('POST', '/v1/systemone', body: {'a': 1});
    final logged = capture.records.map((r) => r.message).join('\n');
    expect(logged, isNot(contains('sk-secret-key-value')));
    expect(logged, contains('***'));
  });

  test('never logs the API key on a failing response, through the error-body '
      'debug log or the retry log', () async {
    final capture = LogCapture('transport');
    addTearDown(capture.cancel);
    var calls = 0;
    final transport = Transport(
      httpClient: MockClient((_) async {
        calls++;
        return calls < 2
            ? http.Response('server exploded', 500)
            : http.Response('{}', 200);
      }),
      baseUrl: 'https://api.example',
      apiKey: 'sk-secret-key-value',
      defaultHeaders: const {},
      logger: capture.logger,
      retry: RetryPolicy(),
      timeout: const Duration(seconds: 5),
      random: _ZeroRandom(),
      sleep: (duration) async {},
      runtime: 'dart/test (test)',
      browser: false,
    );
    await transport.send('GET', '/v1/models');
    final logged = capture.records.map((r) => r.message).join('\n');
    expect(logged, isNot(contains('sk-secret-key-value')));
    expect(logged, contains('***'));
  });
}
