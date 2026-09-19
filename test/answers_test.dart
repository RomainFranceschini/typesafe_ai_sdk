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
