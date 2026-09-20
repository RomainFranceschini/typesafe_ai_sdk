/// The HTTP attempt loop: headers, timeouts, retries, and error mapping.
library;

import 'dart:async';
import 'dart:convert';
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
    required this._httpClient,
    required this.baseUrl,
    required this._apiKey,
    required this._defaultHeaders,
    required this._logger,
    required this.retry,
    required this.timeout,
    Random? random,
    Future<void> Function(Duration)? sleep,
    String? runtime,
    bool? browser,
  }) : _random = random ?? Random(),
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
    // A path that does not start with `/` can shift `baseUrl` into the
    // userinfo component of the parsed URI (e.g. a path beginning with `@`),
    // sending the `Authorization` header to a host the caller never named.
    // No caller reaches `send()` yet, but callers are wired in later tasks,
    // so this is validated here rather than left to whoever adds them.
    if (!path.startsWith('/')) {
      throw TypeSafeError('`path` must start with "/", got "$path".');
    }
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
        await _backOff(
          tag,
          attempt,
          retriesLeft,
          _scrub(error.message),
          null,
          policy,
        );
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
        _readBody(response),
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
      // `.timeout()` abandons this future on expiry, but it does not cancel
      // the underlying send: `package:http` has no `AbortController`
      // equivalent, and request cancellation was deliberately left out of
      // this SDK's design. A slow server can therefore leave up to
      // `maxRetries + 1` requests in flight after `send()` has already
      // thrown or returned.
      return await _httpClient
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      throw ApiTimeoutError(timeout);
    } on http.ClientException catch (error) {
      throw ApiConnectionError(_scrub('Connection error: ${error.message}'));
    } on Exception catch (error) {
      throw ApiConnectionError(_scrub('Connection error: $error'));
    }
  }

  /// Scrubs the API key from a string built from an underlying exception,
  /// in case a third-party [http.Client]'s `toString()` echoes outbound
  /// request headers. No in-tree client does this; this is defense in depth
  /// for the one place the raw key touches request construction.
  String _scrub(String message) => message.replaceAll(_apiKey, '***');

  /// Reads a response body without letting a malformed `Content-Type` throw.
  ///
  /// [http.Response.body] parses `Content-Type` with `MediaType.parse`, which
  /// throws a [FormatException] on a header it cannot fully consume — for
  /// example duplicate `Content-Type` response headers, which HTTP clients
  /// join with `, ` into a single invalid value. That must not crash the
  /// error-mapping path, so a bad header falls back to a best-effort UTF-8
  /// decode of the raw bytes.
  String _readBody(http.Response response) {
    try {
      return response.body;
    } on FormatException {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
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
    void put(String name, String value) =>
        merged[name.trim().toLowerCase()] = value;

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
