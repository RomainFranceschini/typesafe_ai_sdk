/// The HTTP attempt loop: headers, timeouts, retries, and error mapping.
library;

import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

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

      _logger.fine(
        () =>
            '$tag -> $url headers: ${redactHeaders(attemptHeaders)} '
            'body: $body',
      );

      final stopwatch = Stopwatch()..start();
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
        final elapsed = (stopwatch..stop()).elapsedMilliseconds;
        final reason = _scrub(error.message);
        if (retriesLeft <= 0 || !_shouldRetryError(error, policy)) {
          // The terminal outcome, which the retry log below never reports:
          // without this, a request that fails to connect on every attempt
          // goes silent at INFO instead of closing out its transcript.
          _logger.info(() => '$tag <- failed in ${elapsed}ms: $reason');
          rethrow;
        }
        await _backOff(tag, attempt, retriesLeft, reason, null, policy);
        continue;
      }

      final elapsed = (stopwatch..stop()).elapsedMilliseconds;
      final requestId = response.headers[requestIdHeader];
      // A closure, like the FINE calls: the SDK installs no handler, so these
      // strings are usually built only to be discarded.
      _logger.info(
        () =>
            '$tag <- ${response.statusCode} in ${elapsed}ms'
            '${requestId == null ? '' : ' (request $requestId)'}',
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }

      // Scrubbed before it is logged or folded into the error message: a
      // server that echoes the request back — some gateways quote the
      // offending header in a 401 — would otherwise put the API key in the
      // transcript and in `ApiError.message`.
      final errorBody = _scrubBody(parseBody(response.bodyBytes));
      _logger.fine(() => '$tag <- error body $errorBody');
      final error = ApiError.fromResponse(
        response.statusCode,
        errorBody,
        response.headers,
      );
      if (retriesLeft <= 0 || !policy.retriesStatus(response.statusCode)) {
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
    List<int>? body,
    Duration timeout,
  ) async {
    final request = http.Request(method, url)..headers.addAll(headers);
    if (body != null) request.bodyBytes = body;
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

  /// [_scrub] applied to every string inside a parsed response body.
  ///
  /// Only runs on the error path, where the body is small and already being
  /// rebuilt into an exception.
  Object? _scrubBody(Object? value) => switch (value) {
    final String text => _scrub(text),
    final List<Object?> items => [for (final item in items) _scrubBody(item)],
    final Map<Object?, Object?> map => {
      for (final entry in map.entries) entry.key: _scrubBody(entry.value),
    },
    _ => value,
  };

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
    final delay = policy.delayFor(
      attempt: attempt,
      headers: headers,
      random: _random,
    );
    _logger.info(
      () =>
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
    if (!_browser) {
      put('user-agent', sdkIdentifier);
    } else {
      merged.remove('user-agent');
    }
    merged.remove('x-typesafe-retry-count');

    return merged;
  }
}
