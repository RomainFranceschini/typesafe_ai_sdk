/// The HTTP attempt loop: headers, timeouts, retries, and error mapping.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

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
    required this.maxResponseBodyBytes,
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

  /// The largest response body this transport will buffer, in bytes.
  final int maxResponseBodyBytes;

  int _requestCount = 0;

  /// Sends a request, retrying eligible failures, and returns the response.
  ///
  /// Throws [ApiError] for a non-2xx response that survives retries,
  /// [ApiTimeoutError] when an attempt exceeds the timeout,
  /// [ApiConnectionError] when the request cannot be delivered, and
  /// [ApiResponseValidationError] when a successful response exceeds
  /// [maxResponseBodyBytes].
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
    // `ResolvedConfig` validates the client-wide timeout; a per-call override
    // never passes through it, and a non-positive one would expire every
    // attempt before the request left the process.
    if (attemptTimeout <= Duration.zero) {
      throw TypeSafeError(
        '`timeout` must be a positive duration, got $attemptTimeout.',
      );
    }
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
      } on TypeSafeError catch (error) {
        // An attempt can also end on a terminal SDK error that is never
        // retried — an oversized body, say. Without this the request would
        // leave the FINE line above and nothing else in the transcript.
        final elapsed = (stopwatch..stop()).elapsedMilliseconds;
        _logger.info(
          () => '$tag <- failed in ${elapsed}ms: ${_scrub(error.message)}',
        );
        rethrow;
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
    final aborter = Completer<void>();
    void abort() {
      if (!aborter.isCompleted) aborter.complete();
    }

    final request = http.AbortableRequest(
      method,
      url,
      abortTrigger: aborter.future,
    )..headers.addAll(headers);
    if (body != null) request.bodyBytes = body;
    try {
      return await _httpClient
          .send(request)
          .then(_readResponse)
          .timeout(
            timeout,
            onTimeout: () {
              abort();
              throw ApiTimeoutError(timeout);
            },
          );
    } on TypeSafeError {
      // Every SDK error raised inside this attempt — the timeout above, a
      // size rejection from `_readResponse`, anything added later — is
      // already the error the caller should see.
      rethrow;
    } on TimeoutException {
      // Not the `.timeout()` above, which throws `ApiTimeoutError` directly:
      // this is a custom `http.Client` imposing a deadline of its own.
      throw ApiTimeoutError(timeout);
    } on http.ClientException catch (error) {
      throw ApiConnectionError(_scrub('Connection error: ${error.message}'));
    } on Exception catch (error) {
      throw ApiConnectionError(_scrub('Connection error: $error'));
    } finally {
      // Complete the trigger after every terminal outcome so clients do not
      // retain pending abort listeners after a successful response.
      abort();
    }
  }

  /// Reads the body, buffering at most [maxResponseBodyBytes].
  ///
  /// A non-2xx body is truncated at the cap instead of rejected. The status,
  /// request ID and `Retry-After` of an oversized error page are worth more
  /// than its tail, and rejecting it would turn a retryable 502 behind a
  /// chatty gateway into a terminal error the caller cannot classify.
  Future<http.Response> _readResponse(http.StreamedResponse response) async {
    final truncatable = response.statusCode < 200 || response.statusCode >= 300;

    final declaredLength = response.contentLength;
    if (!truncatable &&
        declaredLength != null &&
        declaredLength > maxResponseBodyBytes) {
      // Listen before giving up on the body: IOClient wires the abort trigger
      // to its underlying HttpClientResponse only once the response stream is
      // first subscribed to, so a body left untouched leaves an unread socket
      // active no matter when the request is aborted.
      response.stream
          .listen(null, onError: (Object _, StackTrace _) {})
          .cancel()
          .ignore();
      throw ApiResponseValidationError(
        'Response body declared $declaredLength bytes, exceeding the '
        '$maxResponseBodyBytes-byte limit.',
      );
    }

    // Copies each chunk: a third-party client may hand out a view on a buffer
    // it reuses for the next read, and `takeBytes()` would otherwise return
    // that same buffer as the response body.
    final body = BytesBuilder();
    await for (final chunk in response.stream) {
      final remaining = maxResponseBodyBytes - body.length;
      if (chunk.length > remaining) {
        if (!truncatable) {
          throw ApiResponseValidationError(
            'Response body exceeded the $maxResponseBodyBytes-byte limit.',
          );
        }
        body.add(chunk.sublist(0, remaining));
        // Leaving the loop cancels the subscription, which aborts the rest of
        // the download.
        break;
      }
      body.add(chunk);
    }

    return http.Response.bytes(
      body.takeBytes(),
      response.statusCode,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
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
