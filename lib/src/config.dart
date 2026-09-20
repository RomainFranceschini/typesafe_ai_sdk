/// Client configuration: resolution, precedence, and validation.
library;

import 'errors.dart';
import 'platform/platform.dart' as platform;
import 'retry.dart';

/// Environment variables read when a setting is not passed explicitly.
abstract final class EnvVars {
  /// The API key. Used when `apiKey` is omitted.
  static const String apiKey = 'TYPESAFE_API_KEY';

  /// The API root.
  static const String baseUrl = 'TYPESAFE_BASE_URL';

  /// The default model name.
  static const String defaultModel = 'TYPESAFE_DEFAULT_MODEL';
}

/// The API root used when none is configured.
const String defaultBaseUrl = 'https://api.typesafe.ai';

/// The model used when a request omits one.
const String defaultModelName = 'jev-latest';

/// The per-attempt timeout used when none is configured.
const Duration defaultTimeout = Duration(seconds: 10);

final RegExp _trailingSlashes = RegExp(r'/+$');

String _stripTrailingSlashes(String url) =>
    url.replaceFirst(_trailingSlashes, '');

/// Client settings with precedence and validation already applied.
final class ResolvedConfig {
  ResolvedConfig._({
    required this.apiKey,
    required this.baseUrl,
    required this.defaultModel,
    required this.timeout,
    required this.retry,
    required this.defaultHeaders,
  });

  /// Resolves settings from explicit values, then the environment, then
  /// SDK defaults, validating the result.
  ///
  /// [env] and [browser] exist so tests can supply a fake environment;
  /// they default to the real platform shims.
  factory ResolvedConfig.resolve({
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    Duration? timeout,
    RetryPolicy? retry,
    Map<String, String>? defaultHeaders,
    bool dangerouslyAllowBrowser = false,
    String? Function(String name)? env,
    bool? browser,
  }) {
    final readEnv = env ?? platform.readEnv;
    final inBrowser = browser ?? platform.isBrowser;

    if (inBrowser && !dangerouslyAllowBrowser) {
      throw TypeSafeError(
        'TypeSafeClient is running in a browser, which would expose your API '
        'key to anyone using the page. Call the API from a server instead, or '
        'pass `dangerouslyAllowBrowser: true` if you understand the risk.',
      );
    }

    // Trimmed before use: a key with a trailing newline is a valid header
    // value to this SDK but not to `dart:io`, which would reject it far from
    // here as a retried connection error. Keys read from the environment are
    // trimmed by the platform shim, so this keeps both paths identical.
    final key = (apiKey ?? readEnv(EnvVars.apiKey))?.trim();
    if (key == null) {
      throw TypeSafeError(
        'No API key was provided. Pass `apiKey` to the TypeSafeClient '
        'constructor or set the ${EnvVars.apiKey} environment variable.',
      );
    }
    if (key.isEmpty) {
      throw TypeSafeError('`apiKey` must not be empty or whitespace-only.');
    }

    final resolvedTimeout = timeout ?? defaultTimeout;
    if (resolvedTimeout <= Duration.zero) {
      throw TypeSafeError(
        '`timeout` must be a positive duration, got $resolvedTimeout.',
      );
    }

    final resolvedRetry = retry ?? RetryPolicy();
    _validateRetry(resolvedRetry);

    final resolvedBaseUrl = _stripTrailingSlashes(
      baseUrl ?? readEnv(EnvVars.baseUrl) ?? defaultBaseUrl,
    );
    _validateBaseUrl(resolvedBaseUrl);

    return ResolvedConfig._(
      apiKey: key,
      baseUrl: resolvedBaseUrl,
      defaultModel:
          defaultModel ?? readEnv(EnvVars.defaultModel) ?? defaultModelName,
      timeout: resolvedTimeout,
      retry: resolvedRetry,
      defaultHeaders: Map.unmodifiable(defaultHeaders ?? const {}),
    );
  }

  /// The API key.
  final String apiKey;

  /// The API root, without trailing slashes.
  final String baseUrl;

  /// The model used when a request omits one.
  final String defaultModel;

  /// The per-attempt timeout.
  final Duration timeout;

  /// The retry policy.
  final RetryPolicy retry;

  /// Headers added to every request.
  final Map<String, String> defaultHeaders;

  static void _validateBaseUrl(String baseUrl) {
    if (baseUrl.isEmpty) {
      throw TypeSafeError(
        '`baseUrl` must not be empty. Received an empty string after '
        'stripping trailing slashes.',
      );
    }
    try {
      final uri = Uri.parse(baseUrl);
      if (!uri.isAbsolute) {
        throw TypeSafeError(
          '`baseUrl` must be an absolute URL with a scheme. '
          'Received: "$baseUrl"',
        );
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw TypeSafeError(
          '`baseUrl` must use http or https scheme. '
          'Received: "$baseUrl"',
        );
      }
      // Request paths are appended as text, so a query or fragment here would
      // swallow the API path: `https://host/?x=1` + `/v1/systemone` parses as
      // the site root with the path buried in the query string.
      if (uri.hasQuery || uri.hasFragment) {
        throw TypeSafeError(
          '`baseUrl` must not carry a query string or fragment. '
          'Received: "$baseUrl"',
        );
      }
    } on FormatException catch (e) {
      throw TypeSafeError(
        '`baseUrl` is not a valid URL. Received: "$baseUrl". Error: ${e.message}',
      );
    }
  }

  static void _validateRetry(RetryPolicy policy) {
    if (policy.maxRetries < 0) {
      throw TypeSafeError(
        '`retry.maxRetries` must be non-negative, got ${policy.maxRetries}.',
      );
    }
    if (policy.backoffJitter < 0 || policy.backoffJitter > 1) {
      throw TypeSafeError(
        '`retry.backoffJitter` must be between 0 and 1, got '
        '${policy.backoffJitter}.',
      );
    }
    if (policy.backoffInitial.isNegative ||
        policy.backoffMax.isNegative ||
        policy.maxRetryAfter.isNegative) {
      throw TypeSafeError('`retry` durations must be non-negative.');
    }
    for (final status in policy.httpStatuses) {
      if (status < 100 || status > 999) {
        throw TypeSafeError(
          '`retry.httpStatuses` must contain HTTP status codes, got $status.',
        );
      }
    }
  }
}
