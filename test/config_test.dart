import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/config.dart';
import 'package:typesafe_ai_sdk/src/errors.dart';
import 'package:typesafe_ai_sdk/src/logging.dart';
import 'package:typesafe_ai_sdk/src/retry.dart';

String? Function(String) envOf(Map<String, String> values) {
  return (name) {
    final value = values[name]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  };
}

ResolvedConfig resolve({
  String? apiKey,
  String? baseUrl,
  String? defaultModel,
  LogLevel? logLevel,
  Duration? timeout,
  RetryPolicy? retry,
  Map<String, String> env = const {},
  bool browser = false,
  bool dangerouslyAllowBrowser = false,
}) => ResolvedConfig.resolve(
  apiKey: apiKey,
  baseUrl: baseUrl,
  defaultModel: defaultModel,
  logLevel: logLevel,
  timeout: timeout,
  retry: retry,
  dangerouslyAllowBrowser: dangerouslyAllowBrowser,
  env: envOf(env),
  browser: browser,
);

void main() {
  group('precedence', () {
    test('explicit beats environment beats default', () {
      expect(
        resolve(
          apiKey: 'code',
          baseUrl: 'https://code.example',
          env: {'TYPESAFE_BASE_URL': 'https://env.example'},
        ).baseUrl,
        'https://code.example',
      );
      expect(
        resolve(
          apiKey: 'k',
          env: {'TYPESAFE_BASE_URL': 'https://env.example'},
        ).baseUrl,
        'https://env.example',
      );
      expect(resolve(apiKey: 'k').baseUrl, defaultBaseUrl);
    });

    test('defaults match the JS SDK', () {
      final config = resolve(apiKey: 'k');
      expect(config.defaultModel, defaultModelName);
      expect(config.defaultModel, 'jev-latest');
      expect(config.baseUrl, 'https://api.typesafe.ai');
      expect(config.timeout, const Duration(seconds: 10));
      expect(config.logLevel, LogLevel.warn);
    });

    test('blank environment values are ignored', () {
      expect(
        resolve(apiKey: 'k', env: {'TYPESAFE_BASE_URL': '   '}).baseUrl,
        defaultBaseUrl,
      );
    });

    test('reads the API key from the environment', () {
      expect(resolve(env: {'TYPESAFE_API_KEY': 'from-env'}).apiKey, 'from-env');
    });

    test('strips trailing slashes from the base URL', () {
      expect(
        resolve(apiKey: 'k', baseUrl: 'https://x.example///').baseUrl,
        'https://x.example',
      );
    });

    test('parses the log level from the environment', () {
      expect(
        resolve(apiKey: 'k', env: {'TYPESAFE_LOG_LEVEL': 'debug'}).logLevel,
        LogLevel.debug,
      );
    });
  });

  group('validation', () {
    test('a missing API key names the constructor argument and env var', () {
      expect(
        () => resolve(),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            allOf(contains('apiKey'), contains('TYPESAFE_API_KEY')),
          ),
        ),
      );
    });

    test('rejects an explicitly empty API key', () {
      expect(() => resolve(apiKey: ''), throwsA(isA<TypeSafeError>()));
    });

    test('rejects a whitespace-only API key', () {
      expect(() => resolve(apiKey: '   '), throwsA(isA<TypeSafeError>()));
    });

    test('rejects a non-positive timeout', () {
      expect(
        () => resolve(apiKey: 'k', timeout: Duration.zero),
        throwsA(isA<TypeSafeError>()),
      );
      expect(
        () => resolve(apiKey: 'k', timeout: const Duration(seconds: -1)),
        throwsA(isA<TypeSafeError>()),
      );
    });

    test('rejects a negative maxRetries', () {
      expect(
        () =>
            resolve(apiKey: 'k', retry: RetryPolicy().copyWith(maxRetries: -1)),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('maxRetries'),
          ),
        ),
      );
    });

    test('rejects jitter outside 0..1', () {
      expect(
        () => resolve(
          apiKey: 'k',
          retry: RetryPolicy().copyWith(backoffJitter: 1.5),
        ),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('backoffJitter'),
          ),
        ),
      );
    });

    test('rejects an implausible HTTP status in the retry set', () {
      expect(
        () => resolve(
          apiKey: 'k',
          retry: RetryPolicy().copyWith(httpStatuses: {42}),
        ),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('httpStatuses'),
          ),
        ),
      );
    });

    test('rejects an invalid log level from the environment', () {
      expect(
        () => resolve(apiKey: 'k', env: {'TYPESAFE_LOG_LEVEL': 'loud'}),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('TYPESAFE_LOG_LEVEL'),
          ),
        ),
      );
    });

    test('rejects a scheme-less base URL', () {
      expect(
        () => resolve(apiKey: 'k', baseUrl: 'api.typesafe.ai'),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            allOf(contains('baseUrl'), contains('absolute')),
          ),
        ),
      );
    });

    test('rejects a base URL with invalid scheme', () {
      expect(
        () => resolve(apiKey: 'k', baseUrl: 'ftp://api.typesafe.ai'),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            allOf(contains('baseUrl'), contains('http')),
          ),
        ),
      );
    });

    test('rejects a base URL that is all slashes', () {
      expect(
        () => resolve(apiKey: 'k', baseUrl: '///'),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('baseUrl'),
          ),
        ),
      );
    });
  });

  group('browser guard', () {
    test('refuses to run in a browser by default', () {
      expect(
        () => resolve(apiKey: 'k', browser: true),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('dangerouslyAllowBrowser'),
          ),
        ),
      );
    });

    test('allows browser use when explicitly opted in', () {
      expect(
        resolve(
          apiKey: 'k',
          browser: true,
          dangerouslyAllowBrowser: true,
        ).apiKey,
        'k',
      );
    });

    test('the browser guard fires before the missing-key error', () {
      expect(
        () => resolve(browser: true),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('dangerouslyAllowBrowser'),
          ),
        ),
      );
    });
  });
}
