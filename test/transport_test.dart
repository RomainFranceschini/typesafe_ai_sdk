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

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
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
    int maxResponseBodyBytes = 10 * 1024 * 1024,
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
      maxResponseBodyBytes: maxResponseBodyBytes,
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

    test('aborts the request when an attempt times out', () async {
      final responseStream = StreamController<List<int>>();
      addTearDown(responseStream.close);
      var aborted = false;
      final client = _StreamingClient((request) async {
        if (request case http.AbortableRequest(:final abortTrigger?)) {
          unawaited(abortTrigger.then((_) => aborted = true));
        }
        return http.StreamedResponse(
          responseStream.stream,
          200,
          request: request,
        );
      });
      final transport = Transport(
        httpClient: client,
        baseUrl: 'https://api.example',
        apiKey: 'sk-secret-key-value',
        defaultHeaders: const {},
        logger: _silentLogger(),
        retry: RetryPolicy().copyWith(maxRetries: 0),
        timeout: const Duration(milliseconds: 10),
        maxResponseBodyBytes: 1024,
        runtime: 'dart/test (test)',
        browser: false,
      );

      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(isA<ApiTimeoutError>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(aborted, isTrue);
    });

    test('releases the abort trigger after a completed response', () async {
      var abortTriggerCompleted = false;
      final client = _StreamingClient((request) async {
        if (request case http.AbortableRequest(:final abortTrigger?)) {
          unawaited(abortTrigger.then((_) => abortTriggerCompleted = true));
        }
        return http.StreamedResponse(
          Stream.value(const [1, 2, 3]),
          200,
          request: request,
        );
      });
      final transport = Transport(
        httpClient: client,
        baseUrl: 'https://api.example',
        apiKey: 'sk-secret-key-value',
        defaultHeaders: const {},
        logger: _silentLogger(),
        retry: RetryPolicy().copyWith(maxRetries: 0),
        timeout: const Duration(seconds: 5),
        maxResponseBodyBytes: 1024,
        runtime: 'dart/test (test)',
        browser: false,
      );

      await transport.send('GET', '/v1/models');
      await Future<void>.delayed(Duration.zero);

      expect(abortTriggerCompleted, isTrue);
    });
  });

  group('response size', () {
    test('rejects an oversized declared content length', () async {
      var calls = 0;
      var responseStreamCanceled = false;
      final releaseCancellation = Completer<void>();
      final responseStream = StreamController<List<int>>(
        onCancel: () {
          responseStreamCanceled = true;
          return releaseCancellation.future;
        },
      );
      addTearDown(() async {
        if (!releaseCancellation.isCompleted) releaseCancellation.complete();
        if (responseStream.hasListener) await responseStream.close();
      });
      final client = _StreamingClient((request) async {
        calls++;
        return http.StreamedResponse(
          responseStream.stream,
          200,
          contentLength: 4,
          request: request,
        );
      });
      final transport = Transport(
        httpClient: client,
        baseUrl: 'https://api.example',
        apiKey: 'sk-secret-key-value',
        defaultHeaders: const {},
        logger: _silentLogger(),
        retry: RetryPolicy(),
        timeout: const Duration(milliseconds: 20),
        maxResponseBodyBytes: 3,
        runtime: 'dart/test (test)',
        browser: false,
      );

      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(isA<ApiResponseValidationError>()),
      );
      expect(calls, 1);
      expect(responseStreamCanceled, isTrue);
    });

    test('rejects an oversized streamed body without retrying', () async {
      var calls = 0;
      final client = _StreamingClient((request) async {
        calls++;
        return http.StreamedResponse(
          Stream.fromIterable(const [
            [1, 2],
            [3, 4],
          ]),
          200,
          request: request,
        );
      });
      final transport = Transport(
        httpClient: client,
        baseUrl: 'https://api.example',
        apiKey: 'sk-secret-key-value',
        defaultHeaders: const {},
        logger: _silentLogger(),
        retry: RetryPolicy(),
        timeout: const Duration(seconds: 5),
        maxResponseBodyBytes: 3,
        runtime: 'dart/test (test)',
        browser: false,
      );

      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(isA<ApiResponseValidationError>()),
      );
      expect(calls, 1);
    });

    test('accepts a declared content length exactly at the limit', () async {
      final client = _StreamingClient(
        (request) async => http.StreamedResponse(
          Stream.value(utf8.encode('{}!')),
          200,
          contentLength: 3,
          request: request,
        ),
      );
      final transport = Transport(
        httpClient: client,
        baseUrl: 'https://api.example',
        apiKey: 'sk-secret-key-value',
        defaultHeaders: const {},
        logger: _silentLogger(),
        retry: RetryPolicy(),
        timeout: const Duration(seconds: 5),
        maxResponseBodyBytes: 3,
        runtime: 'dart/test (test)',
        browser: false,
      );

      final response = await transport.send('GET', '/v1/models');
      expect(response.bodyBytes, hasLength(3));
    });

    test('accepts a streamed body exactly at the limit', () async {
      final client = _StreamingClient(
        (request) async => http.StreamedResponse(
          Stream.fromIterable(const [
            [1, 2],
            [3],
          ]),
          200,
          request: request,
        ),
      );
      final transport = Transport(
        httpClient: client,
        baseUrl: 'https://api.example',
        apiKey: 'sk-secret-key-value',
        defaultHeaders: const {},
        logger: _silentLogger(),
        retry: RetryPolicy(),
        timeout: const Duration(seconds: 5),
        maxResponseBodyBytes: 3,
        runtime: 'dart/test (test)',
        browser: false,
      );

      final response = await transport.send('GET', '/v1/models');
      expect(response.bodyBytes, [1, 2, 3]);
    });

    test('truncates an oversized error body and still retries it', () async {
      var calls = 0;
      final client = _StreamingClient((request) async {
        calls++;
        if (calls == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('x' * 4096)),
            500,
            contentLength: 4096,
            request: request,
            headers: const {'x-typesafe-request-id': 'req_big'},
          );
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode('{}')),
          200,
          request: request,
        );
      });
      final transport = Transport(
        httpClient: client,
        baseUrl: 'https://api.example',
        apiKey: 'sk-secret-key-value',
        defaultHeaders: const {},
        logger: _silentLogger(),
        retry: RetryPolicy(),
        timeout: const Duration(seconds: 5),
        maxResponseBodyBytes: 8,
        sleep: (duration) async => slept.add(duration),
        random: _ZeroRandom(),
        runtime: 'dart/test (test)',
        browser: false,
      );

      final response = await transport.send('GET', '/v1/models');
      expect(response.statusCode, 200);
      expect(calls, 2);
    });

    test('surfaces an oversized error body as a typed ApiError', () async {
      final client = _StreamingClient(
        (request) async => http.StreamedResponse(
          Stream.value(utf8.encode('{"error":"nope"}${'.' * 4096}')),
          401,
          request: request,
          headers: const {'x-typesafe-request-id': 'req_big'},
        ),
      );
      final transport = Transport(
        httpClient: client,
        baseUrl: 'https://api.example',
        apiKey: 'sk-secret-key-value',
        defaultHeaders: const {},
        logger: _silentLogger(),
        retry: RetryPolicy(),
        timeout: const Duration(seconds: 5),
        maxResponseBodyBytes: 16,
        runtime: 'dart/test (test)',
        browser: false,
      );

      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(
          isA<AuthenticationError>()
              .having((e) => e.requestId, 'requestId', 'req_big')
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('logs the terminal size failure', () async {
      final capture = LogCapture('transport');
      addTearDown(capture.cancel);
      final client = _StreamingClient(
        (request) async => http.StreamedResponse(
          Stream.value(const [1, 2, 3, 4]),
          200,
          contentLength: 4,
          request: request,
        ),
      );
      final transport = Transport(
        httpClient: client,
        baseUrl: 'https://api.example',
        apiKey: 'sk-secret-key-value',
        defaultHeaders: const {},
        logger: capture.logger,
        retry: RetryPolicy(),
        timeout: const Duration(seconds: 5),
        maxResponseBodyBytes: 3,
        runtime: 'dart/test (test)',
        browser: false,
      );

      await expectLater(
        transport.send('GET', '/v1/models'),
        throwsA(isA<ApiResponseValidationError>()),
      );
      expect(
        capture.records.map((r) => r.message).join('\n'),
        contains('<- failed in'),
      );
    });
  });

  group('timeout mapping', () {
    test(
      'maps a TimeoutException from the client to ApiTimeoutError',
      () async {
        var calls = 0;
        final client = _StreamingClient((request) async {
          calls++;
          throw TimeoutException('client deadline');
        });
        final transport = Transport(
          httpClient: client,
          baseUrl: 'https://api.example',
          apiKey: 'sk-secret-key-value',
          defaultHeaders: const {},
          logger: _silentLogger(),
          retry: RetryPolicy().copyWith(maxRetries: 2, retryTimeouts: false),
          timeout: const Duration(seconds: 5),
          maxResponseBodyBytes: 1024,
          sleep: (duration) async => slept.add(duration),
          random: _ZeroRandom(),
          runtime: 'dart/test (test)',
          browser: false,
        );

        await expectLater(
          transport.send('GET', '/v1/models'),
          throwsA(
            isA<ApiTimeoutError>().having(
              (e) => e.timeout,
              'timeout',
              const Duration(seconds: 5),
            ),
          ),
        );
        // `retryTimeouts: false` applies, so the attempt is not repeated.
        expect(calls, 1);
      },
    );

    test('rejects a non-positive per-call timeout', () async {
      final transport = transportFor((_) async => http.Response('{}', 200));
      await expectLater(
        transport.send('GET', '/v1/models', timeout: Duration.zero),
        throwsA(isA<TypeSafeError>()),
      );
      expect(requests, isEmpty);
    });
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
      maxResponseBodyBytes: 10 * 1024 * 1024,
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
            // Echoing the request back is what some gateways do on an auth
            // failure, and it is the only way this test can observe a leak.
            ? http.Response('{"error":"invalid key sk-secret-key-value"}', 500)
            : http.Response('{}', 200);
      }),
      baseUrl: 'https://api.example',
      apiKey: 'sk-secret-key-value',
      defaultHeaders: const {},
      logger: capture.logger,
      retry: RetryPolicy(),
      timeout: const Duration(seconds: 5),
      maxResponseBodyBytes: 10 * 1024 * 1024,
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

  test('never carries the API key into the thrown error', () async {
    final capture = LogCapture('transport');
    addTearDown(capture.cancel);
    final transport = Transport(
      httpClient: MockClient(
        (_) async =>
            http.Response('{"error":"invalid key sk-secret-key-value"}', 401),
      ),
      baseUrl: 'https://api.example',
      apiKey: 'sk-secret-key-value',
      defaultHeaders: const {},
      logger: capture.logger,
      retry: RetryPolicy(),
      timeout: const Duration(seconds: 5),
      maxResponseBodyBytes: 10 * 1024 * 1024,
      random: _ZeroRandom(),
      sleep: (duration) async {},
      runtime: 'dart/test (test)',
      browser: false,
    );
    await expectLater(
      transport.send('GET', '/v1/models'),
      throwsA(
        isA<ApiError>()
            .having(
              (e) => e.message,
              'message',
              isNot(contains('sk-secret-key-value')),
            )
            .having((e) => e.message, 'message', contains('***'))
            .having(
              (e) => '${e.body}',
              'body',
              isNot(contains('sk-secret-key-value')),
            ),
      ),
    );
  });
}
