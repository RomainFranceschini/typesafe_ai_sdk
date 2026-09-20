/// The HTTP attempt loop: headers, timeouts, retries, and error mapping.
library;

import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'json.dart';
import 'logging.dart';
import 'platform/platform.dart' as platform;
import 'retry.dart';
import 'version.dart';

/// The value sent in the SDK identification headers.
final String sdkIdentifier = 'typesafe-ai-sdk-dart/$packageVersion';

/// Sends requests to the API, retrying eligible failures.
final class Transport {
  /// Creates a transport.
  ///
  /// [random], [sleep], [runtime], and [browser] exist for tests; they default
  /// to real implementations.
  Transport({
    required http.Client httpClient,
    required this.baseUrl,
    required String apiKey,
    required Map<String, String> defaultHeaders,
    required Logger logger,
    required this.retry,
    required this.timeout,
    Random? random,
    Future<void> Function(Duration)? sleep,
    String? runtime,
    bool? browser,
  })
    // These four fields are private while their constructor parameters keep
    // public (non-underscored) names, so an initializing formal is not an
    // option here: `this._httpClient` would force callers to write
    // `Transport(_httpClient: ...)`, which is not a valid public label.
    // ignore: prefer_initializing_formals
    : _httpClient = httpClient,
       // ignore: prefer_initializing_formals
       _apiKey = apiKey,
       // ignore: prefer_initializing_formals
       _defaultHeaders = defaultHeaders,
       // ignore: prefer_initializing_formals
       _logger = logger,
       _random = random ?? Random(),
       _sleep = sleep ?? Future<void>.delayed,
       _runtime = runtime ?? platform.describeRuntime(),
       _browser = browser ?? platform.isBrowser;

  final http.Client _httpClient;
  final String _apiKey;
  final Map<String, String> _defaultHeaders;
  final Logger _logger;
  final Random _random;
  final Future<void> Function(Duration) _sleep;
  final String _runtime;
  final bool _browser;

  /// The API root, without trailing slashes.
  final String baseUrl;

  /// The default retry policy.
  final RetryPolicy retry;

  /// The default per-attempt timeout.
  final Duration timeout;

  int _requestCount = 0;

  /// Sends a request, retrying eligible failures, and returns the response.
  ///
  /// Throws [ApiError] for a non-2xx response that survives retries,
  /// [ApiTimeoutError] when an attempt exceeds the timeout, and
  /// [ApiConnectionError] when the request cannot be delivered.
  Future<http.Response> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? headers,
    RetryPolicy? retry,
    Duration? timeout,
  }) async {
    final policy = retry ?? this.retry;
    final attemptTimeout = timeout ?? this.timeout;
    final url = Uri.parse('$baseUrl$path');
    final encoded = body == null ? null : encodeBody(body, 'request body');
    final baseHeaders = _mergeHeaders(headers, hasBody: body != null);
    // Numbered so concurrent requests can be told apart in the logs.
    final tag = '#${++_requestCount} $method $path';

    for (var attempt = 0; ; attempt++) {
      final retriesLeft = policy.maxRetries - attempt;
      final attemptHeaders = attempt == 0
          ? baseHeaders
          : {...baseHeaders, 'x-typesafe-retry-count': '$attempt'};

      _logger.debug('$tag -> $url', {
        'headers': redactHeaders(attemptHeaders),
        'body': body,
      });

      final started = DateTime.now();
      http.Response response;
      try {
        response = await _attempt(
          method,
          url,
          attemptHeaders,
          encoded,
          attemptTimeout,
        );
      } on ApiConnectionError catch (error) {
        if (retriesLeft <= 0 || !_shouldRetryError(error, policy)) rethrow;
        await _backOff(tag, attempt, retriesLeft, error.message, null, policy);
        continue;
      }

      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final requestId = response.headers[requestIdHeader];
      _logger.info(
        '$tag <- ${response.statusCode} in ${elapsed}ms'
        '${requestId == null ? '' : ' (request $requestId)'}',
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }

      final errorBody = parseBody(
        response.body,
        response.headers['content-type'],
      );
      _logger.debug('$tag <- error body', errorBody);
      final error = ApiError.fromResponse(
        response.statusCode,
        errorBody,
        response.headers,
      );
      if (retriesLeft <= 0 || !isRetryableStatus(response.statusCode, policy)) {
        throw error;
      }
      await _backOff(
        tag,
        attempt,
        retriesLeft,
        '${response.statusCode}',
        response.headers,
        policy,
      );
    }
  }

  /// One HTTP round trip, including reading the body, under one timeout.
  Future<http.Response> _attempt(
    String method,
    Uri url,
    Map<String, String> headers,
    String? body,
    Duration timeout,
  ) async {
    final request = http.Request(method, url)..headers.addAll(headers);
    if (body != null) request.body = body;
    try {
      return await _httpClient
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      throw ApiTimeoutError(timeout);
    } on http.ClientException catch (error) {
      throw ApiConnectionError('Connection error: ${error.message}');
    } on Exception catch (error) {
      throw ApiConnectionError('Connection error: $error');
    }
  }

  bool _shouldRetryError(ApiConnectionError error, RetryPolicy policy) =>
      error is ApiTimeoutError
      ? policy.retryTimeouts
      : policy.retryConnectionErrors;

  Future<void> _backOff(
    String tag,
    int attempt,
    int retriesLeft,
    String reason,
    Map<String, String>? headers,
    RetryPolicy policy,
  ) async {
    final delay = retryDelay(attempt, headers, policy, _random);
    _logger.info(
      '$tag retrying in ${delay.inMilliseconds}ms '
      '(retry ${attempt + 1}/${attempt + retriesLeft}) after $reason',
    );
    await _sleep(delay);
  }

  /// Merges headers so caller values can never displace protected ones.
  Map<String, String> _mergeHeaders(
    Map<String, String>? perCall, {
    required bool hasBody,
  }) {
    final merged = <String, String>{};
    void put(String name, String value) => merged[name.toLowerCase()] = value;

    _defaultHeaders.forEach(put);
    perCall?.forEach(put);

    // Protected headers go last, so they win regardless of caller casing.
    put('authorization', 'Bearer $_apiKey');
    put('accept', 'application/json');
    put('x-typesafe-sdk', sdkIdentifier);
    put('x-typesafe-runtime', _runtime);
    if (hasBody) put('content-type', 'application/json');
    // Browsers reject attempts to set User-Agent; X-TypeSafe-SDK carries the
    // same information and is allowed.
    if (!_browser) put('user-agent', sdkIdentifier);
    merged.remove('x-typesafe-retry-count');

    return merged;
  }
}
