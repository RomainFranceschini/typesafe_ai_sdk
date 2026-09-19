import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/errors.dart';

void main() {
  group('fromResponse maps status codes', () {
    final cases = <int, Type>{
      400: BadRequestError,
      401: AuthenticationError,
      403: PermissionDeniedError,
      404: NotFoundError,
      422: UnprocessableEntityError,
      429: RateLimitError,
      500: InternalServerError,
      503: InternalServerError,
    };
    cases.forEach((status, type) {
      test('$status -> $type', () {
        expect(ApiError.fromResponse(status, null, {}).runtimeType, type);
      });
    });

    test('an unmapped status falls back to ApiError', () {
      expect(ApiError.fromResponse(418, null, {}).runtimeType, ApiError);
    });
  });

  group('message extraction', () {
    test('uses a bare string body', () {
      expect(ApiError.fromResponse(400, 'nope', {}).message, '400 nope');
    });

    test('uses a string error field', () {
      expect(
        ApiError.fromResponse(400, {'error': 'bad'}, {}).message,
        '400 bad',
      );
    });

    test('uses a nested error message', () {
      expect(
        ApiError.fromResponse(400, {
          'error': {'message': 'nested'},
        }, {}).message,
        '400 nested',
      );
    });

    test('uses a message field', () {
      expect(
        ApiError.fromResponse(400, {'message': 'plain'}, {}).message,
        '400 plain',
      );
    });

    test('uses a string detail field', () {
      expect(
        ApiError.fromResponse(400, {'detail': 'because'}, {}).message,
        '400 because',
      );
    });

    test('formats a validation array, dropping the body prefix', () {
      final error = ApiError.fromResponse(422, {
        'detail': [
          {
            'loc': ['body', 'questions'],
            'msg': 'field required',
          },
          {
            'loc': ['body', 'state'],
            'msg': 'must be a string',
          },
        ],
      }, {});
      expect(
        error.message,
        '422 questions: field required; state: must be a string',
      );
    });

    test('describes an empty body', () {
      expect(
        ApiError.fromResponse(500, null, {}).message,
        '500 status code (no body)',
      );
    });

    test('truncates a long raw body to 200 characters', () {
      final error = ApiError.fromResponse(400, {'unrelated': 'x' * 500}, {});
      // '400 ' + 200 characters + the ellipsis
      expect(error.message.length, 4 + 200 + 1);
      expect(error.message, endsWith('…'));
    });
  });

  group('metadata', () {
    test('captures the request ID header', () {
      final error = ApiError.fromResponse(500, null, {
        'x-typesafe-request-id': 'req_123',
      });
      expect(error.requestId, 'req_123');
    });

    test('requestId is null when the header is absent', () {
      expect(ApiError.fromResponse(500, null, {}).requestId, isNull);
    });

    test('RateLimitError exposes the server retry delay', () {
      final error = ApiError.fromResponse(429, null, {'retry-after': '30'});
      expect((error as RateLimitError).retryAfter, const Duration(seconds: 30));
    });

    test('RateLimitError retryAfter is null without the header', () {
      final error = ApiError.fromResponse(429, null, {}) as RateLimitError;
      expect(error.retryAfter, isNull);
    });
  });

  group('non-HTTP errors', () {
    test('ApiTimeoutError reports its timeout and is a connection error', () {
      final error = ApiTimeoutError(const Duration(seconds: 10));
      expect(error, isA<ApiConnectionError>());
      expect(error.timeout, const Duration(seconds: 10));
      expect(error.message, 'Request timed out after 10000ms.');
    });

    test('toString names the concrete subclass', () {
      expect(
        NotFoundError(404, null, const {}).toString(),
        startsWith('NotFoundError: '),
      );
    });

    test('ApiResponseValidationError carries a path', () {
      final error = ApiResponseValidationError('bad label', path: 'answers.x');
      expect(error.path, 'answers.x');
      expect(error.message, 'bad label');
    });
  });
}
