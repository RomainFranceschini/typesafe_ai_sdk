/// Retry defaults, delay calculation, and `Retry-After` parsing.
library;

import 'dart:math';

final Set<int> _defaultRetryStatuses = {
  408,
  429,
  for (var status = 500; status < 600; status++) status,
};

/// Retry configuration.
///
/// Per-call overrides are produced with [copyWith] against the client's
/// policy, which is itself built over these defaults.
class RetryPolicy {
  /// Creates a retry policy, defaulting every unset field to the SDK default.
  RetryPolicy({
    this.maxRetries = 2,
    this.backoffInitial = const Duration(milliseconds: 500),
    this.backoffMax = const Duration(seconds: 5),
    this.backoffJitter = 0.25,
    Set<int>? httpStatuses,
    this.respectRetryAfter = true,
    this.maxRetryAfter = const Duration(seconds: 60),
    this.retryConnectionErrors = true,
    this.retryTimeouts = true,
  }) : httpStatuses = Set.unmodifiable(httpStatuses ?? _defaultRetryStatuses);

  /// Maximum retries after the initial attempt; `0` disables retries.
  final int maxRetries;

  /// First backoff delay, doubled each attempt up to [backoffMax].
  final Duration backoffInitial;

  /// Maximum backoff delay.
  final Duration backoffMax;

  /// Fraction of each backoff delay randomly subtracted, from 0 to 1.
  final double backoffJitter;

  /// HTTP status codes to retry.
  final Set<int> httpStatuses;

  /// Whether to honor `Retry-After` and `retry-after-ms` response headers.
  final bool respectRetryAfter;

  /// Maximum server retry delay; longer delays fall back to backoff.
  final Duration maxRetryAfter;

  /// Whether to retry connection failures.
  final bool retryConnectionErrors;

  /// Whether to retry request timeouts.
  final bool retryTimeouts;

  /// Returns a copy of this policy with the named fields replaced.
  RetryPolicy copyWith({
    int? maxRetries,
    Duration? backoffInitial,
    Duration? backoffMax,
    double? backoffJitter,
    Set<int>? httpStatuses,
    bool? respectRetryAfter,
    Duration? maxRetryAfter,
    bool? retryConnectionErrors,
    bool? retryTimeouts,
  }) {
    return RetryPolicy(
      maxRetries: maxRetries ?? this.maxRetries,
      backoffInitial: backoffInitial ?? this.backoffInitial,
      backoffMax: backoffMax ?? this.backoffMax,
      backoffJitter: backoffJitter ?? this.backoffJitter,
      httpStatuses: httpStatuses ?? this.httpStatuses,
      respectRetryAfter: respectRetryAfter ?? this.respectRetryAfter,
      maxRetryAfter: maxRetryAfter ?? this.maxRetryAfter,
      retryConnectionErrors:
          retryConnectionErrors ?? this.retryConnectionErrors,
      retryTimeouts: retryTimeouts ?? this.retryTimeouts,
    );
  }
}

/// Whether [policy] retries responses with [status].
bool isRetryableStatus(int status, RetryPolicy policy) =>
    policy.httpStatuses.contains(status);

const List<String> _weekdays = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

final RegExp _imfFixdate = RegExp(
  r'^(\w{3}), (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);

/// Parses an RFC 7231 IMF-fixdate, returning `null` when [value] is not one.
///
/// `dart:io`'s `HttpDate.parse` is unavailable on web, so this package carries
/// its own parser for the only date format `Retry-After` may use.
DateTime? parseHttpDate(String value) {
  final match = _imfFixdate.firstMatch(value.trim());
  if (match == null) return null;
  if (!_weekdays.contains(match.group(1))) return null;
  final month = _months.indexOf(match.group(3)!);
  if (month < 0) return null;
  return DateTime.utc(
    int.parse(match.group(4)!),
    month + 1,
    int.parse(match.group(2)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
    int.parse(match.group(7)!),
  );
}

/// Parses `retry-after-ms` or `Retry-After` into a delay.
///
/// `retry-after-ms` wins when both are present. Returns `null` when neither
/// header carries a valid, non-negative delay.
Duration? parseRetryAfter(Map<String, String> headers, {DateTime? now}) {
  final millis = headers['retry-after-ms'];
  if (millis != null) {
    final parsed = num.tryParse(millis.trim());
    if (parsed != null && parsed >= 0) {
      return Duration(milliseconds: parsed.round());
    }
    return null;
  }

  final raw = headers['retry-after'];
  if (raw == null) return null;

  final seconds = num.tryParse(raw.trim());
  if (seconds != null) {
    return seconds >= 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : null;
  }

  final date = parseHttpDate(raw);
  if (date == null) return null;
  final remaining = date.difference(now ?? DateTime.now().toUtc());
  return remaining.isNegative ? Duration.zero : remaining;
}

/// The delay before a zero-based retry [attempt].
///
/// Uses an allowed server delay when present, otherwise capped exponential
/// backoff with jitter subtracted.
Duration retryDelay(
  int attempt,
  Map<String, String>? headers,
  RetryPolicy policy,
  Random random,
) {
  if (policy.respectRetryAfter && headers != null) {
    final serverDelay = parseRetryAfter(headers);
    if (serverDelay != null && serverDelay <= policy.maxRetryAfter) {
      return serverDelay;
    }
  }
  final exponential = policy.backoffInitial.inMilliseconds * pow(2, attempt);
  final capped = min(
    exponential.toDouble(),
    policy.backoffMax.inMilliseconds.toDouble(),
  );
  final jittered = capped * (1 - random.nextDouble() * policy.backoffJitter);
  return Duration(milliseconds: jittered.round());
}
