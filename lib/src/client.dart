/// The API client.
library;

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'answers.dart';
import 'config.dart';
import 'errors.dart';
import 'json.dart';
import 'logging.dart';
import 'questions.dart';
import 'resources/models.dart';
import 'response.dart';
import 'retry.dart';
import 'transport.dart';

/// A client for the TypeSafe AI API.
///
/// Explicit options take precedence over environment variables, then SDK
/// defaults. Call [close] when finished, unless you supplied [httpClient], in
/// which case closing it is yours to do.
final class TypeSafeClient {
  /// Creates a client.
  ///
  /// Throws [TypeSafeError] when the API key is missing, configuration is
  /// invalid, or the SDK is running in a browser without
  /// [dangerouslyAllowBrowser].
  factory TypeSafeClient({
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    Logger? logger,
    RetryPolicy? retry,
    Duration? timeout,
    int? maxResponseBodyBytes,
    Map<String, String>? defaultHeaders,
    http.Client? httpClient,
    bool dangerouslyAllowBrowser = false,
  }) {
    final config = ResolvedConfig.resolve(
      apiKey: apiKey,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      timeout: timeout,
      maxResponseBodyBytes: maxResponseBodyBytes,
      retry: retry,
      defaultHeaders: defaultHeaders,
      dangerouslyAllowBrowser: dangerouslyAllowBrowser,
    );
    final base = logger ?? defaultLogger;
    final client = httpClient ?? http.Client();
    final transport = Transport(
      httpClient: client,
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      defaultHeaders: config.defaultHeaders,
      logger: childLogger(base, 'transport'),
      retry: config.retry,
      timeout: config.timeout,
      maxResponseBodyBytes: config.maxResponseBodyBytes,
    );
    return TypeSafeClient._(
      config: config,
      logger: childLogger(base, 'response'),
      httpClient: client,
      ownsHttpClient: httpClient == null,
      transport: transport,
      models: Models(transport),
    );
  }

  TypeSafeClient._({
    required this._config,
    required this._logger,
    required this._httpClient,
    required this._ownsHttpClient,
    required this._transport,
    required this.models,
  });

  final ResolvedConfig _config;
  final Logger _logger;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Transport _transport;

  /// The models available to the account.
  final Models models;

  /// The API root, without trailing slashes.
  String get baseUrl => _config.baseUrl;

  /// The model used when a request omits one.
  String get defaultModel => _config.defaultModel;

  /// The retry policy. Build per-call overrides with `copyWith`.
  RetryPolicy get retry => _config.retry;

  /// The per-attempt timeout.
  Duration get timeout => _config.timeout;

  /// The largest response body the client will buffer, in bytes.
  int get maxResponseBodyBytes => _config.maxResponseBodyBytes;

  /// Answers named questions about text or structured state.
  ///
  /// [state] may be a string, a JSON-encodable map or list, `null`, or any
  /// object exposing a `toJson()` method.
  ///
  /// Throws [TypeSafeError] when [questions] is empty or [state] cannot be
  /// encoded, [ApiError] for a non-2xx response that survives retries,
  /// [ApiConnectionError] when the request cannot be delivered, and
  /// [ApiResponseValidationError] when the response is malformed or larger
  /// than [maxResponseBodyBytes].
  ///
  /// ```dart
  /// final billing = Noul(instructions: 'Is this about billing?');
  /// final response = await client.systemOne(
  ///   state: 'I was charged twice.',
  ///   questions: {'billing': billing},
  /// );
  /// print(response.get(billing).noul);
  /// ```
  Future<SystemOneResponse> systemOne({
    required Object? state,
    required Map<String, Question<Answer>> questions,
    String? model,
    Duration? timeout,
    RetryPolicy? retry,
    Map<String, String>? headers,
  }) async {
    if (questions.isEmpty) {
      throw TypeSafeError('At least one question is required.');
    }

    final body = <String, Object?>{
      'state': state,
      'questions': {
        for (final entry in questions.entries) entry.key: entry.value.toJson(),
      },
      'model': model ?? _config.defaultModel,
    };

    final response = await _transport.send(
      'POST',
      '/v1/systemone',
      body: body,
      headers: headers,
      retry: retry,
      timeout: timeout,
    );

    return decodeSystemOne(
      body: parseBody(response.bodyBytes),
      questions: questions,
      httpResponse: response,
      logger: _logger,
    );
  }

  /// Releases the underlying HTTP client.
  ///
  /// Does nothing when the client was supplied to the constructor, since it
  /// belongs to the caller.
  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }
}
