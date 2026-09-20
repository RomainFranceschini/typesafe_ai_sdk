import 'dart:math';

import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/retry.dart';

/// A `Random` that always returns [value], making backoff deterministic.
class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

void main() {
  group('RetryPolicy defaults', () {
    test('match the JS SDK', () {
      final policy = RetryPolicy();
      expect(policy.maxRetries, 2);
      expect(policy.backoffInitial, const Duration(milliseconds: 500));
      expect(policy.backoffMax, const Duration(seconds: 5));
      expect(policy.backoffJitter, 0.25);
      expect(policy.respectRetryAfter, isTrue);
      expect(policy.maxRetryAfter, const Duration(seconds: 60));
      expect(policy.retryConnectionErrors, isTrue);
      expect(policy.retryTimeouts, isTrue);
    });

    test('retryable statuses are 408, 429, and 5xx', () {
      final policy = RetryPolicy();
      expect(policy.retriesStatus(408), isTrue);
      expect(policy.retriesStatus(429), isTrue);
      expect(policy.retriesStatus(500), isTrue);
      expect(policy.retriesStatus(599), isTrue);
      expect(policy.retriesStatus(400), isFalse);
      expect(policy.retriesStatus(404), isFalse);
      expect(policy.retriesStatus(600), isFalse);
    });

    test('copyWith overrides only the named fields', () {
      final merged = RetryPolicy().copyWith(maxRetries: 0);
      expect(merged.maxRetries, 0);
      expect(merged.backoffInitial, const Duration(milliseconds: 500));
    });

    test('httpStatuses is unmodifiable', () {
      expect(() => RetryPolicy().httpStatuses.add(418), throwsUnsupportedError);
    });
  });

  group('parseRetryAfter', () {
    test('prefers retry-after-ms', () {
      expect(
        parseRetryAfter({'retry-after-ms': '1500', 'retry-after': '9'}),
        const Duration(milliseconds: 1500),
      );
    });

    test('reads retry-after as seconds', () {
      expect(parseRetryAfter({'retry-after': '3'}), const Duration(seconds: 3));
    });

    test('clamps an oversized retry-after instead of overflowing', () {
      // (1e13 * 1000).round() saturates at the int64 maximum, and Duration
      // multiplies by another 1000 for microseconds, wrapping negative.
      final delay = parseRetryAfter({'retry-after': '10000000000000'});
      expect(delay!.isNegative, isFalse);
      expect(delay, const Duration(days: 365));
    });

    test('clamps an oversized retry-after-ms instead of overflowing', () {
      final delay = parseRetryAfter({'retry-after-ms': '99999999999999999999'});
      expect(delay!.isNegative, isFalse);
      expect(delay, const Duration(days: 365));
    });

    test('reads retry-after as an HTTP date', () {
      final now = DateTime.utc(2026, 9, 19, 12, 0, 0);
      expect(
        parseRetryAfter({
          'retry-after': 'Sat, 19 Sep 2026 12:00:30 GMT',
        }, now: now),
        const Duration(seconds: 30),
      );
    });

    test('clamps a past HTTP date to zero', () {
      final now = DateTime.utc(2026, 9, 19, 12, 0, 0);
      expect(
        parseRetryAfter({
          'retry-after': 'Sat, 19 Sep 2026 11:59:00 GMT',
        }, now: now),
        Duration.zero,
      );
    });

    test('returns null for absent, negative, or unparseable values', () {
      expect(parseRetryAfter({}), isNull);
      expect(parseRetryAfter({'retry-after': '-5'}), isNull);
      expect(parseRetryAfter({'retry-after': 'soon'}), isNull);
      expect(parseRetryAfter({'retry-after-ms': 'soon'}), isNull);
    });

    test('returns null for Infinity in retry-after-ms', () {
      expect(parseRetryAfter({'retry-after-ms': 'Infinity'}), isNull);
    });

    test('returns null for Infinity in retry-after seconds', () {
      expect(parseRetryAfter({'retry-after': 'Infinity'}), isNull);
    });

    test('falls through to retry-after when retry-after-ms is invalid', () {
      expect(
        parseRetryAfter({'retry-after-ms': 'soon', 'retry-after': '2'}),
        const Duration(seconds: 2),
      );
    });

    test('falls through to retry-after when retry-after-ms is negative', () {
      expect(
        parseRetryAfter({'retry-after-ms': '-5', 'retry-after': '3'}),
        const Duration(seconds: 3),
      );
    });

    test('returns null for IMF-fixdate with day 32', () {
      // Day 32 is out of range for any month
      expect(
        parseRetryAfter({'retry-after': 'Sat, 32 Sep 2026 12:00:30 GMT'}),
        isNull,
      );
    });

    test('returns null for IMF-fixdate with hour 25', () {
      // Hour 25 is out of range
      expect(
        parseRetryAfter({'retry-after': 'Sat, 19 Sep 2026 25:00:30 GMT'}),
        isNull,
      );
    });
  });

  group('RetryPolicy.delayFor', () {
    test('doubles each attempt and caps at backoffMax', () {
      final policy = RetryPolicy();
      final random = _FixedRandom(0);
      expect(
        policy.delayFor(attempt: 0, random: random),
        const Duration(milliseconds: 500),
      );
      expect(
        policy.delayFor(attempt: 1, random: random),
        const Duration(milliseconds: 1000),
      );
      expect(
        policy.delayFor(attempt: 2, random: random),
        const Duration(milliseconds: 2000),
      );
      expect(
        policy.delayFor(attempt: 9, random: random),
        const Duration(seconds: 5),
      );
    });

    test('falls back to backoff when the server delay overflows', () {
      // A negative delay would slip past the maxRetryAfter check and retry
      // with no wait at all.
      expect(
        RetryPolicy().delayFor(
          attempt: 0,
          random: _FixedRandom(0),
          headers: {'retry-after': '10000000000000'},
        ),
        const Duration(milliseconds: 500),
      );
    });

    test('stays capped at backoffMax for a very deep attempt', () {
      // An integer 2^attempt wraps past attempt 63, capping to a zero delay.
      expect(
        RetryPolicy().delayFor(attempt: 70, random: _FixedRandom(0)),
        const Duration(seconds: 5),
      );
    });

    test('subtracts jitter as a fraction of the delay', () {
      final policy = RetryPolicy();
      // 500ms * (1 - 1.0 * 0.25) == 375ms
      expect(
        policy.delayFor(attempt: 0, random: _FixedRandom(1)),
        const Duration(milliseconds: 375),
      );
    });

    test('honors a server delay within the cap', () {
      expect(
        RetryPolicy().delayFor(
          attempt: 0,
          headers: {'retry-after': '2'},
          random: _FixedRandom(0),
        ),
        const Duration(seconds: 2),
      );
    });

    test('falls back to backoff when the server delay exceeds the cap', () {
      expect(
        RetryPolicy().delayFor(
          attempt: 0,
          headers: {'retry-after': '120'},
          random: _FixedRandom(0),
        ),
        const Duration(milliseconds: 500),
      );
    });

    test('ignores server delays when respectRetryAfter is false', () {
      final policy = RetryPolicy().copyWith(respectRetryAfter: false);
      expect(
        policy.delayFor(
          attempt: 0,
          headers: {'retry-after': '2'},
          random: _FixedRandom(0),
        ),
        const Duration(milliseconds: 500),
      );
    });
  });
}
