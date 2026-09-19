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
      expect(isRetryableStatus(408, policy), isTrue);
      expect(isRetryableStatus(429, policy), isTrue);
      expect(isRetryableStatus(500, policy), isTrue);
      expect(isRetryableStatus(599, policy), isTrue);
      expect(isRetryableStatus(400, policy), isFalse);
      expect(isRetryableStatus(404, policy), isFalse);
      expect(isRetryableStatus(600, policy), isFalse);
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

  group('retryDelay', () {
    test('doubles each attempt and caps at backoffMax', () {
      final policy = RetryPolicy();
      final random = _FixedRandom(0);
      expect(
        retryDelay(0, null, policy, random),
        const Duration(milliseconds: 500),
      );
      expect(
        retryDelay(1, null, policy, random),
        const Duration(milliseconds: 1000),
      );
      expect(
        retryDelay(2, null, policy, random),
        const Duration(milliseconds: 2000),
      );
      expect(retryDelay(9, null, policy, random), const Duration(seconds: 5));
    });

    test('subtracts jitter as a fraction of the delay', () {
      final policy = RetryPolicy();
      // 500ms * (1 - 1.0 * 0.25) == 375ms
      expect(
        retryDelay(0, null, policy, _FixedRandom(1)),
        const Duration(milliseconds: 375),
      );
    });

    test('honors a server delay within the cap', () {
      expect(
        retryDelay(0, {'retry-after': '2'}, RetryPolicy(), _FixedRandom(0)),
        const Duration(seconds: 2),
      );
    });

    test('falls back to backoff when the server delay exceeds the cap', () {
      expect(
        retryDelay(0, {'retry-after': '120'}, RetryPolicy(), _FixedRandom(0)),
        const Duration(milliseconds: 500),
      );
    });

    test('ignores server delays when respectRetryAfter is false', () {
      final policy = RetryPolicy().copyWith(respectRetryAfter: false);
      expect(
        retryDelay(0, {'retry-after': '2'}, policy, _FixedRandom(0)),
        const Duration(milliseconds: 500),
      );
    });
  });
}
