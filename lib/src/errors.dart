/// The SDK's error hierarchy.
library;

import 'retry.dart';

/// The response header carrying the API's request identifier.
const String requestIdHeader = 'x-typesafe-request-id';

const int _maxRawBodyInMessage = 200;

/// The base class for every error this SDK throws.
class TypeSafeError implements Exception {
  /// Creates an error described by [message].
  TypeSafeError(this.message);

  /// A human-readable description of what went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

String? _extractMessage(Object? body) {
  if (body is String) return body.isEmpty ? null : body;
  if (body is! Map) return null;

  final error = body['error'];
  if (error is String) return error;
  if (error is Map && error['message'] is String) {
    return error['message'] as String;
  }

  final message = body['message'];
  if (message is String) return message;

  final detail = body['detail'];
  if (detail is String) return detail;
  if (detail is Map && detail['message'] is String) {
    return detail['message'] as String;
  }
  if (detail is List) return _describeValidationErrors(detail);

  return null;
}

/// Formats FastAPI-style validation errors as `path: message` entries.
String? _describeValidationErrors(List<Object?> errors) {
  final parts = <String>[];
  for (final entry in errors) {
    if (entry is! Map) continue;
    final msg = entry['msg'];
    if (msg is! String) continue;
    final loc = entry['loc'];
    final path = loc is List
        ? (loc.isNotEmpty && loc.first == 'body' ? loc.skip(1) : loc).join('.')
        : '';
    parts.add(path.isEmpty ? msg : '$path: $msg');
  }
  return parts.isEmpty ? null : parts.join('; ');
}

/// An unsuccessful HTTP response from the API.
class ApiError extends TypeSafeError {
  /// Creates an error for a non-2xx [statusCode].
  ApiError({
    required this.statusCode,
    required this.body,
    required this.headers,
    String? message,
  }) : requestId = headers[requestIdHeader],
       super(message ?? _describe(statusCode, body));

  /// The HTTP response status code.
  final int statusCode;

  /// Parsed JSON, response text, or `null` for an empty body or a body
  /// containing literal JSON `null`. Callers cannot distinguish these cases.
  final Object? body;

  /// The HTTP response headers, with lowercased names.
  final Map<String, String> headers;

  /// The request identifier, or `null` when the API did not send one.
  final String? requestId;

  static String _describe(int status, Object? body) {
    final detail = _extractMessage(body);
    if (detail != null) return '$status $detail';
    if (body == null) return '$status status code (no body)';
    final raw = body is String ? body : body.toString();
    if (raw.length > _maxRawBodyInMessage) {
      return '$status ${raw.substring(0, _maxRawBodyInMessage)}…';
    }
    return '$status $raw';
  }

  /// Creates the error subclass matching [status].
  static ApiError fromResponse(
    int status,
    Object? body,
    Map<String, String> headers,
  ) => switch (status) {
    400 => BadRequestError(statusCode: status, body: body, headers: headers),
    401 => AuthenticationError(
      statusCode: status,
      body: body,
      headers: headers,
    ),
    403 => PermissionDeniedError(
      statusCode: status,
      body: body,
      headers: headers,
    ),
    404 => NotFoundError(statusCode: status, body: body, headers: headers),
    422 => UnprocessableEntityError(
      statusCode: status,
      body: body,
      headers: headers,
    ),
    429 => RateLimitError(statusCode: status, body: body, headers: headers),
    >= 500 => InternalServerError(
      statusCode: status,
      body: body,
      headers: headers,
    ),
    _ => ApiError(statusCode: status, body: body, headers: headers),
  };
}

/// HTTP 400: the request is invalid.
class BadRequestError extends ApiError {
  /// Creates an HTTP 400 error.
  BadRequestError({
    required super.statusCode,
    required super.body,
    required super.headers,
  });
}

/// HTTP 401: authentication failed.
class AuthenticationError extends ApiError {
  /// Creates an HTTP 401 error.
  AuthenticationError({
    required super.statusCode,
    required super.body,
    required super.headers,
  });
}

/// HTTP 403: access is denied.
class PermissionDeniedError extends ApiError {
  /// Creates an HTTP 403 error.
  PermissionDeniedError({
    required super.statusCode,
    required super.body,
    required super.headers,
  });
}

/// HTTP 404: the resource was not found.
class NotFoundError extends ApiError {
  /// Creates an HTTP 404 error.
  NotFoundError({
    required super.statusCode,
    required super.body,
    required super.headers,
  });
}

/// HTTP 422: request validation failed.
class UnprocessableEntityError extends ApiError {
  /// Creates an HTTP 422 error.
  UnprocessableEntityError({
    required super.statusCode,
    required super.body,
    required super.headers,
  });
}

/// HTTP 429: the rate limit was exceeded.
class RateLimitError extends ApiError {
  /// Creates an HTTP 429 error, reading the server's retry delay.
  RateLimitError({
    required super.statusCode,
    required super.body,
    required super.headers,
  }) : retryAfter = parseRetryAfter(headers);

  /// The server's requested retry delay, when it sent a valid one.
  final Duration? retryAfter;
}

/// HTTP 5xx: the server failed to handle the request.
class InternalServerError extends ApiError {
  /// Creates an HTTP 5xx error.
  InternalServerError({
    required super.statusCode,
    required super.body,
    required super.headers,
  });
}

/// The request could not be delivered or the response could not be read.
class ApiConnectionError extends TypeSafeError {
  /// Creates a connection error.
  ApiConnectionError([super.message = 'Connection error.']);
}

/// The response did not arrive within the configured timeout.
class ApiTimeoutError extends ApiConnectionError {
  /// Creates a timeout error for a request bounded by [timeout].
  ApiTimeoutError(this.timeout)
    : super('Request timed out after ${timeout.inMilliseconds}ms.');

  /// The timeout that elapsed.
  final Duration timeout;
}

/// The response did not match the shape this SDK expects.
class ApiResponseValidationError extends TypeSafeError {
  /// Creates a validation error, optionally naming the offending [path].
  ApiResponseValidationError(super.message, {this.path});

  /// A dotted path to the offending field, when one is known.
  final String? path;
}
