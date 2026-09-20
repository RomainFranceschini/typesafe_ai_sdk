import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/answers.dart';
import 'package:typesafe_ai_sdk/src/errors.dart';
import 'package:typesafe_ai_sdk/src/logging.dart';
import 'package:typesafe_ai_sdk/src/questions.dart';
import 'package:typesafe_ai_sdk/src/response.dart';

enum _Tone { calm, frustrated, angry }

class _RecordingLogger implements Logger {
  final List<String> warnings = [];
  @override
  void debug(String message, [Object? data]) {}
  @override
  void info(String message, [Object? data]) {}
  @override
  void warn(String message, [Object? data]) => warnings.add(message);
  @override
  void error(String message, [Object? data]) {}
}

http.Response _http({Map<String, String> headers = const {}}) =>
    http.Response('{}', 200, headers: headers);

void main() {
  final isBilling = Noul(instructions: 'Billing?');
  final tone = Choice({
    _Tone.calm: null,
    _Tone.frustrated: null,
    _Tone.angry: null,
  });
  final urgency = Score.levels(['can wait', 'today', 'right now']);

  Map<String, Question<Answer>> questionSet() => {
    'isBilling': isBilling,
    'tone': tone,
    'urgency': urgency,
  };

  Map<String, Object?> body() => {
    'model': 'jev-latest',
    'usage': {'input_tokens': 120, 'output_tokens': 8},
    'answers': {
      'isBilling': {'type': 'noul', 'noul': 0.91},
      'tone': {
        'type': 'choice',
        'choice': 'frustrated',
        'confidence': 0.7,
        'probabilities': {'calm': 0.1, 'frustrated': 0.7, 'angry': 0.2},
      },
      'urgency': {
        'type': 'score',
        'score': 1.4,
        'confidence': 0.8,
        'legend': {'0': 'can wait', '1': 'today', '2': 'right now'},
        'probabilities': {'0': 0.2, '1': 0.6, '2': 0.2},
      },
    },
  };

  SystemOneResponse decode({
    Map<String, Object?>? override,
    Map<String, Question<Answer>>? questions,
    Logger? logger,
    Map<String, String> headers = const {},
  }) => decodeSystemOne(
    body: override ?? body(),
    questions: questions ?? questionSet(),
    httpResponse: _http(headers: headers),
    logger: logger ?? _RecordingLogger(),
  );

  group('metadata', () {
    test('reads model and usage', () {
      final response = decode();
      expect(response.model, 'jev-latest');
      expect(response.usage.inputTokens, 120);
      expect(response.usage.outputTokens, 8);
    });

    test('usage fields are null when the API omits them', () {
      final response = decode(
        override: {...body(), 'usage': <String, Object?>{}},
      );
      expect(response.usage.inputTokens, isNull);
    });

    test('usage fields are null when non-numeric rather than throwing', () {
      final response = decode(
        override: {
          ...body(),
          'usage': {'input_tokens': 'a lot', 'output_tokens': null},
        },
      );
      expect(response.usage.inputTokens, isNull);
      expect(response.usage.outputTokens, isNull);
    });

    test('captures the request ID', () {
      final response = decode(headers: {'x-typesafe-request-id': 'req_9'});
      expect(response.requestId, 'req_9');
    });
  });

  group('typed lookup', () {
    test('get returns the precise answer type for each question', () {
      final response = decode();

      final billing = response.get(isBilling);
      expect(billing.noul, 0.91);

      final toneAnswer = response.get(tone);
      expect(toneAnswer.choice, _Tone.frustrated);
      expect(toneAnswer.probabilities[_Tone.angry], 0.2);

      final urgencyAnswer = response.get(urgency);
      expect(urgencyAnswer.score, 1.4);
      expect(urgencyAnswer.legend[1], 'today');
      expect(urgencyAnswer.nearestLevel, 1);
    });

    test('the raw answers map stays available by name', () {
      expect(decode().answers['isBilling'], isA<NoulAnswer>());
    });

    test('get rejects a question that was not part of the request', () {
      expect(
        () => decode().get(Noul(instructions: 'unrelated')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('not part of the request'),
          ),
        ),
      );
    });

    test('get rejects a question registered under two names', () {
      final shared = Noul(instructions: 'shared');
      final response = decode(
        questions: {'first': shared, 'second': shared},
        override: {
          'model': 'm',
          'usage': <String, Object?>{},
          'answers': {
            'first': {'type': 'noul', 'noul': 0.1},
            'second': {'type': 'noul', 'noul': 0.2},
          },
        },
      );
      expect(
        () => response.get(shared),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('first'), contains('second')),
          ),
        ),
      );
    });
  });

  group('forward compatibility', () {
    test('drops answers with an unrecognized type and warns', () {
      final logger = _RecordingLogger();
      final raw = body();
      (raw['answers']! as Map<String, Object?>)['future'] = {
        'type': 'quantum',
        'value': 1,
      };
      final response = decode(override: raw, logger: logger);
      expect(response.answers.containsKey('future'), isFalse);
      expect(logger.warnings.single, contains('quantum'));
      // The known answers still decode.
      expect(response.get(isBilling).noul, 0.91);
    });

    test('drops an answer no question asked for and warns', () {
      final logger = _RecordingLogger();
      final raw = body();
      (raw['answers']! as Map<String, Object?>)['stray'] = {
        'type': 'noul',
        'noul': 0.5,
      };
      final response = decode(override: raw, logger: logger);
      expect(response.answers.containsKey('stray'), isFalse);
      expect(logger.warnings.single, contains('stray'));
    });
  });

  group('validation', () {
    test('rejects a non-map body', () {
      expect(
        () => decodeSystemOne(
          body: 'not json',
          questions: questionSet(),
          httpResponse: _http(),
          logger: _RecordingLogger(),
        ),
        throwsA(isA<ApiResponseValidationError>()),
      );
    });

    test('rejects an answer without a string type', () {
      expect(
        () => decode(
          override: {
            'model': 'm',
            'usage': <String, Object?>{},
            'answers': {
              'isBilling': {'noul': 0.5},
            },
          },
        ),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.path,
            'path',
            'answers.isBilling.type',
          ),
        ),
      );
    });

    test('rejects a missing model', () {
      expect(
        () => decode(
          override: {
            'usage': <String, Object?>{},
            'answers': <String, Object?>{},
          },
        ),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.path,
            'path',
            'model',
          ),
        ),
      );
    });
  });
}
