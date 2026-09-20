import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/answers.dart';

enum _Urgency { canWait, thisWeek, today, rightNow }

void main() {
  test('NoulAnswer carries a probability', () {
    expect(const NoulAnswer(0.82).noul, 0.82);
  });

  test('ChoiceAnswer carries the label type', () {
    const answer = ChoiceAnswer<_Urgency>(
      choice: _Urgency.today,
      confidence: 0.7,
      probabilities: {_Urgency.today: 0.7, _Urgency.canWait: 0.3},
    );
    expect(answer.choice, _Urgency.today);
    expect(answer.probabilities[_Urgency.today], 0.7);
  });

  group('ScoreAnswer.nearestLevel', () {
    ScoreAnswer<_Urgency> answerFor(double score) => ScoreAnswer<_Urgency>(
      score: score,
      confidence: 0.5,
      legend: const {},
      probabilities: const {},
      scale: _Urgency.values,
    );

    test('rounds to the closest level', () {
      expect(answerFor(2.4).nearestLevel, _Urgency.today);
      expect(answerFor(2.6).nearestLevel, _Urgency.rightNow);
      expect(answerFor(0.0).nearestLevel, _Urgency.canWait);
    });

    test('clamps beyond either end of the scale', () {
      expect(answerFor(-3.0).nearestLevel, _Urgency.canWait);
      expect(answerFor(99.0).nearestLevel, _Urgency.rightNow);
    });
  });

  group('value equality', () {
    test('NoulAnswer compares by probability', () {
      expect(const NoulAnswer(0.5), const NoulAnswer(0.5));
      expect(const NoulAnswer(0.5).hashCode, const NoulAnswer(0.5).hashCode);
      expect(const NoulAnswer(0.5), isNot(const NoulAnswer(0.6)));
    });

    test('ChoiceAnswer compares probabilities deeply', () {
      const a = ChoiceAnswer<_Urgency>(
        choice: _Urgency.today,
        confidence: 0.7,
        probabilities: {_Urgency.today: 0.7, _Urgency.canWait: 0.3},
      );
      const same = ChoiceAnswer<_Urgency>(
        choice: _Urgency.today,
        confidence: 0.7,
        probabilities: {_Urgency.today: 0.7, _Urgency.canWait: 0.3},
      );
      const different = ChoiceAnswer<_Urgency>(
        choice: _Urgency.today,
        confidence: 0.7,
        probabilities: {_Urgency.today: 0.9, _Urgency.canWait: 0.1},
      );
      expect(a, same);
      expect(a.hashCode, same.hashCode);
      expect(a, isNot(different));
    });

    test('ChoiceAnswer of a different label type is not equal', () {
      const typed = ChoiceAnswer<_Urgency>(
        choice: _Urgency.today,
        confidence: 1,
        probabilities: {},
      );
      const stringly = ChoiceAnswer<String>(
        choice: 'today',
        confidence: 1,
        probabilities: {},
      );
      expect(typed, isNot(stringly));
    });

    test('ScoreAnswer compares its rubric, probabilities, and scale', () {
      ScoreAnswer<_Urgency> build(List<_Urgency> scale) =>
          ScoreAnswer<_Urgency>(
            score: 1.5,
            confidence: 0.6,
            legend: const {_Urgency.canWait: 'later'},
            probabilities: const {_Urgency.canWait: 1.0},
            scale: scale,
          );
      expect(build(_Urgency.values), build(_Urgency.values));
      expect(build(_Urgency.values).hashCode, build(_Urgency.values).hashCode);
      expect(
        build(_Urgency.values),
        isNot(build(const [_Urgency.canWait, _Urgency.today])),
      );
    });

    test('toString renders the fields', () {
      expect(const NoulAnswer(0.5).toString(), 'NoulAnswer(0.5)');
      expect(
        const ChoiceAnswer<String>(
          choice: 'a',
          confidence: 0.5,
          probabilities: {'a': 0.5},
        ).toString(),
        'ChoiceAnswer(choice: a, confidence: 0.5, probabilities: {a: 0.5})',
      );
    });
  });

  test('Answer is sealed, so switch is exhaustive', () {
    // This compiles only while Answer has exactly these three subtypes.
    // A new subtype makes this switch a compile error, which is the point.
    String describe(Answer answer) => switch (answer) {
      NoulAnswer() => 'noul',
      ChoiceAnswer() => 'choice',
      ScoreAnswer() => 'score',
    };
    expect(describe(const NoulAnswer(1)), 'noul');
  });
}
