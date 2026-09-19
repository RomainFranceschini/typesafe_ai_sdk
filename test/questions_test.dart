import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/errors.dart';
import 'package:typesafe_ai_sdk/src/questions.dart';

enum _Tone { calm, frustrated, angry }

enum _Gapped { zero, one, two }

void main() {
  group('Noul', () {
    test('encodes with instructions and omits absent criteria', () {
      final question = Noul(instructions: 'Is this billing?');
      expect(question.toJson(), {
        'type': 'noul',
        'instructions': 'Is this billing?',
      });
    });

    test('encodes criteria using the wire keys true and false', () {
      final question = Noul(
        instructions: null,
        criteria: const NoulCriteria(whenTrue: 'yes it is', whenFalse: null),
      );
      expect(question.toJson(), {
        'type': 'noul',
        'instructions': null,
        'criteria': {'true': 'yes it is', 'false': null},
      });
    });

    test('decodes a probability', () {
      final answer = Noul().decodeAnswer({
        'type': 'noul',
        'noul': 0.75,
      }, 'isBilling');
      expect(answer.noul, 0.75);
    });

    test('rejects a non-numeric probability', () {
      expect(
        () => Noul().decodeAnswer({'type': 'noul', 'noul': 'high'}, 'x'),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.path,
            'path',
            'answers.x.noul',
          ),
        ),
      );
    });
  });

  group('Choice with String labels', () {
    final question = Choice({
      'billing': null,
      'technical': 'anything technical',
    }, instructions: 'What is this about?');

    test('infers Choice<String>', () {
      expect(question, isA<Choice<String>>());
    });

    test('encodes criteria as a label map', () {
      expect(question.toJson(), {
        'type': 'choice',
        'instructions': 'What is this about?',
        'criteria': {'billing': null, 'technical': 'anything technical'},
      });
    });

    test('decodes the selected label and probabilities', () {
      final answer = question.decodeAnswer({
        'type': 'choice',
        'choice': 'billing',
        'confidence': 0.9,
        'probabilities': {'billing': 0.9, 'technical': 0.1},
      }, 'category');
      expect(answer.choice, 'billing');
      expect(answer.confidence, 0.9);
      expect(answer.probabilities, {'billing': 0.9, 'technical': 0.1});
    });

    test('rejects a non-numeric probability value', () {
      expect(
        () => question.decodeAnswer({
          'type': 'choice',
          'choice': 'billing',
          'confidence': 0.9,
          'probabilities': {'billing': 'high', 'technical': 0.1},
        }, 'category'),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.path,
            'path',
            'answers.category.probabilities',
          ),
        ),
      );
    });

    test('rejects a null probability value', () {
      expect(
        () => question.decodeAnswer({
          'type': 'choice',
          'choice': 'billing',
          'confidence': 0.9,
          'probabilities': {'billing': null, 'technical': 0.1},
        }, 'category'),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.path,
            'path',
            'answers.category.probabilities',
          ),
        ),
      );
    });
  });

  group('Choice with enum labels', () {
    final question = Choice({
      _Tone.calm: null,
      _Tone.frustrated: 'visibly annoyed',
      _Tone.angry: null,
    }, instructions: 'Customer tone?');

    test('infers Choice<_Tone>', () {
      expect(question, isA<Choice<_Tone>>());
    });

    test('encodes enum labels by name', () {
      expect((question.toJson()['criteria']! as Map<String, Object?>).keys, [
        'calm',
        'frustrated',
        'angry',
      ]);
    });

    test('decodes back into enum values', () {
      final answer = question.decodeAnswer({
        'type': 'choice',
        'choice': 'frustrated',
        'confidence': 0.6,
        'probabilities': {'calm': 0.1, 'frustrated': 0.6, 'angry': 0.3},
      }, 'tone');
      expect(answer.choice, _Tone.frustrated);
      expect(answer.probabilities[_Tone.angry], 0.3);
    });

    test('rejects a label outside the criteria', () {
      expect(
        () => question.decodeAnswer({
          'type': 'choice',
          'choice': 'elated',
          'confidence': 0.6,
          'probabilities': <String, Object?>{},
        }, 'tone'),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.message,
            'message',
            allOf(contains('elated'), contains('tone')),
          ),
        ),
      );
    });

    test('rejects empty criteria', () {
      expect(() => Choice<String>(const {}), throwsA(isA<TypeSafeError>()));
    });

    test('rejects a label type that is neither String nor enum', () {
      expect(
        () => Choice({1: null, 2: null}),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('Choice.custom'),
          ),
        ),
      );
    });
  });

  group('Choice.custom', () {
    test('rejects empty criteria', () {
      expect(
        () => Choice<int>.custom(
          criteria: const {},
          encodeLabel: (label) => label.toString(),
          decodeLabel: (raw) => int.parse(raw),
        ),
        throwsA(isA<TypeSafeError>()),
      );
    });

    test('rejects labels that collide on their wire encoding', () {
      expect(
        () => Choice<int>.custom(
          criteria: const {1: null, 2: null},
          encodeLabel: (label) => 'x',
          decodeLabel: (raw) => 1,
        ),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('encodeLabel must be injective'),
          ),
        ),
      );
    });

    test('accepts distinct wire encodings', () {
      final question = Choice<int>.custom(
        criteria: const {1: 'one', 2: 'two'},
        encodeLabel: (label) => 'n$label',
        decodeLabel: (raw) => int.parse(raw.substring(1)),
      );
      expect(question.toJson()['criteria'], {'n1': 'one', 'n2': 'two'});
    });
  });

  group('Score.levels', () {
    final question = Score.levels([
      'can wait',
      'today',
      'right now',
    ], instructions: 'Urgency?');

    test('infers Score<int>', () {
      expect(question, isA<Score<int>>());
    });

    test('encodes criteria as an ordered list', () {
      expect(question.toJson(), {
        'type': 'score',
        'instructions': 'Urgency?',
        'criteria': ['can wait', 'today', 'right now'],
      });
    });

    test('requires at least two levels', () {
      expect(
        () => Score.levels(['only one']),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('at least two'),
          ),
        ),
      );
    });

    test('decodes score, legend, and probabilities keyed by int', () {
      final answer = question.decodeAnswer({
        'type': 'score',
        'score': 1.4,
        'confidence': 0.8,
        'legend': {'0': 'can wait', '1': 'today', '2': 'right now'},
        'probabilities': {'0': 0.2, '1': 0.6, '2': 0.2},
      }, 'urgency');
      expect(answer.score, 1.4);
      expect(answer.legend[1], 'today');
      expect(answer.probabilities[2], 0.2);
      expect(answer.nearestLevel, 1);
    });

    test('rejects a non-numeric probability value', () {
      expect(
        () => question.decodeAnswer({
          'type': 'score',
          'score': 1.0,
          'confidence': 0.8,
          'legend': {'0': 'can wait', '1': 'today', '2': 'right now'},
          'probabilities': {'0': 'low', '1': 0.6, '2': 0.2},
        }, 'urgency'),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.path,
            'path',
            'answers.urgency.probabilities',
          ),
        ),
      );
    });

    test('rejects a null probability value', () {
      expect(
        () => question.decodeAnswer({
          'type': 'score',
          'score': 1.0,
          'confidence': 0.8,
          'legend': {'0': 'can wait', '1': 'today', '2': 'right now'},
          'probabilities': {'0': null, '1': 0.6, '2': 0.2},
        }, 'urgency'),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.path,
            'path',
            'answers.urgency.probabilities',
          ),
        ),
      );
    });

    test('rejects a score key outside the rubric', () {
      expect(
        () => question.decodeAnswer({
          'type': 'score',
          'score': 1.0,
          'confidence': 0.8,
          'legend': {'0': 'can wait', '1': 'today', '5': 'right now'},
          'probabilities': {'0': 0.2, '1': 0.6, '2': 0.2},
        }, 'urgency'),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.message,
            'message',
            contains('outside its rubric'),
          ),
        ),
      );
    });

    test('rejects a non-numeric score key', () {
      expect(
        () => question.decodeAnswer({
          'type': 'score',
          'score': 1.0,
          'confidence': 0.8,
          'legend': {'low': 'can wait', '1': 'today', '2': 'right now'},
          'probabilities': {'0': 0.2, '1': 0.6, '2': 0.2},
        }, 'urgency'),
        throwsA(
          isA<ApiResponseValidationError>().having(
            (e) => e.message,
            'message',
            contains('non-numeric score key'),
          ),
        ),
      );
    });
  });

  group('Score.ofEnum', () {
    test('encodes in enum index order regardless of literal order', () {
      final question = Score.ofEnum({
        _Tone.angry: 'angry',
        _Tone.calm: 'calm',
        _Tone.frustrated: 'frustrated',
      });
      expect(question.toJson()['criteria'], ['calm', 'frustrated', 'angry']);
    });

    test('decodes probabilities keyed by enum value', () {
      final question = Score.ofEnum({
        _Tone.calm: 'calm',
        _Tone.frustrated: 'f',
        _Tone.angry: 'a',
      });
      final answer = question.decodeAnswer({
        'type': 'score',
        'score': 1.6,
        'confidence': 0.5,
        'legend': {'0': 'calm', '1': 'f', '2': 'a'},
        'probabilities': {'0': 0.1, '1': 0.4, '2': 0.5},
      }, 'tone');
      expect(answer.probabilities[_Tone.angry], 0.5);
      expect(answer.nearestLevel, _Tone.angry);
    });

    test('allows omitting trailing values, which shift nothing', () {
      final question = Score.ofEnum({_Gapped.zero: 'a', _Gapped.one: 'b'});
      expect(question.toJson()['criteria'], ['a', 'b']);
    });

    test('rejects a gap in the middle, which would shift later levels', () {
      expect(
        () => Score.ofEnum({_Gapped.zero: 'a', _Gapped.two: 'c'}),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('contiguous'),
          ),
        ),
      );
    });
  });

  group('validateQuestions', () {
    test('rejects an empty question set', () {
      expect(
        () => validateQuestions({}),
        throwsA(
          isA<TypeSafeError>().having(
            (e) => e.message,
            'message',
            contains('At least one question'),
          ),
        ),
      );
    });

    test('accepts a non-empty question set', () {
      expect(() => validateQuestions({'a': Noul()}), returnsNormally);
    });
  });

  test('a mismatched answer type is rejected', () {
    expect(
      () => Noul().decodeAnswer({'type': 'choice', 'noul': 0.5}, 'x'),
      throwsA(
        isA<ApiResponseValidationError>().having(
          (e) => e.message,
          'message',
          contains('choice'),
        ),
      ),
    );
  });

  test('knownAnswerTypes covers noul, choice, and score', () {
    expect(knownAnswerTypes, {'noul', 'choice', 'score'});
  });
}
