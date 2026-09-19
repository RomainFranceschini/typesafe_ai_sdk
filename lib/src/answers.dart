/// The answers returned by System One, one per question.
library;

/// An answer to a single question.
///
/// This type is sealed, so a `switch` over an answer of unknown kind is
/// checked for exhaustiveness by the analyzer.
sealed class Answer {
  /// Creates an answer.
  const Answer();
}

/// A yes/no answer.
final class NoulAnswer extends Answer {
  /// Creates a yes/no answer with probability [noul].
  const NoulAnswer(this.noul);

  /// Probability of a yes answer, from zero to one.
  final double noul;
}

/// A selected label and the probabilities across all labels.
final class ChoiceAnswer<L extends Object> extends Answer {
  /// Creates a choice answer.
  const ChoiceAnswer({
    required this.choice,
    required this.confidence,
    required this.probabilities,
  });

  /// The selected label.
  final L choice;

  /// Reported confidence in the selected label.
  final double confidence;

  /// Probabilities keyed by label.
  final Map<L, double> probabilities;
}

/// An expected score with its rubric and probabilities.
final class ScoreAnswer<L extends Object> extends Answer {
  /// Creates a score answer.
  const ScoreAnswer({
    required this.score,
    required this.confidence,
    required this.legend,
    required this.probabilities,
    required this.scale,
  });

  /// The expected score.
  ///
  /// This is a continuous expected value and may fall between rubric levels,
  /// which is why it is a `double` even when [L] is an enum. Use
  /// [nearestLevel] for the closest discrete level.
  final double score;

  /// Reported confidence in the score.
  final double confidence;

  /// Rubric descriptions keyed by level.
  final Map<L, Object?> legend;

  /// Probabilities keyed by level.
  final Map<L, double> probabilities;

  /// The levels in wire order; position equals the score index.
  final List<L> scale;

  /// The discrete level closest to [score], clamped to the ends of [scale].
  L get nearestLevel => scale[score.round().clamp(0, scale.length - 1).toInt()];
}
