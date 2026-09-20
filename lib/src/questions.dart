/// The question hierarchy, its wire encoding, and answer decoding.
library;

import 'answers.dart';
import 'errors.dart';

/// The answer `type` discriminators this SDK version understands.
const Set<String> knownAnswerTypes = {'noul', 'choice', 'score'};

/// A question about the request's state.
///
/// The type parameter [A] is the answer this question produces. That link is
/// what lets `SystemOneResponse.get` return a precise answer type.
sealed class Question<A extends Answer> {
  /// Creates a question.
  Question({this.instructions});

  /// The question as text, a JSON-encodable value, or `null`.
  final Object? instructions;

  /// This question's wire form.
  Map<String, Object?> toJson();

  /// Decodes [json] into this question's answer type.
  ///
  /// [name] is the question's key in the request, used in error messages.
  A decodeAnswer(Map<String, Object?> json, String name);
}

/// Throws unless [json] carries the answer type [expected].
///
/// A free function rather than a method on [Question]: the class is sealed, so
/// there are no external implementers to offer it to, and as a member it would
/// surface in the public API for no caller's benefit.
void _checkType(Map<String, Object?> json, String expected, String name) {
  final type = json['type'];
  if (type != expected) {
    throw ApiResponseValidationError(
      'Question "$name" expected a "$expected" answer but the API returned '
      '"$type".',
      path: 'answers.$name.type',
    );
  }
}

/// Converts [value] to a `double`, or throws a validation error naming
/// [name] and [field] when [value] is not numeric.
///
/// This is used both for top-level answer fields and for individual entries
/// inside a `probabilities` map, so a missing, `null`, or non-numeric
/// probability always surfaces as an [ApiResponseValidationError] instead of
/// a raw `TypeError` from an unchecked cast.
double _asDouble(Object? value, String name, String field) {
  if (value is! num) {
    throw ApiResponseValidationError(
      'Question "$name" expected a numeric `$field`, got '
      '${value.runtimeType}.',
      path: 'answers.$name.$field',
    );
  }
  return value.toDouble();
}

/// Reads a required number from an answer body.
double _requireDouble(Map<String, Object?> json, String field, String name) =>
    _asDouble(json[field], name, field);

/// Reads a required map from an answer body.
Map<String, Object?> _requireMap(
  Map<String, Object?> json,
  String field,
  String name,
) {
  final value = json[field];
  if (value is! Map) {
    throw ApiResponseValidationError(
      'Question "$name" expected a `$field` object, got ${value.runtimeType}.',
      path: 'answers.$name.$field',
    );
  }
  return value.cast<String, Object?>();
}

/// Descriptions of a yes/no question's two outcomes.
final class NoulCriteria {
  /// Creates criteria, leaving either outcome undescribed when `null`.
  const NoulCriteria({this.whenTrue, this.whenFalse});

  /// Description of the yes outcome. Encoded as the wire key `true`.
  final Object? whenTrue;

  /// Description of the no outcome. Encoded as the wire key `false`.
  final Object? whenFalse;

  /// This criteria's wire form.
  ///
  /// The wire keys are `true` and `false`, which are reserved words in Dart,
  /// so the fields are named [whenTrue] and [whenFalse] instead.
  Map<String, Object?> toJson() => {'true': whenTrue, 'false': whenFalse};
}

/// A yes/no question.
final class Noul extends Question<NoulAnswer> {
  /// Creates a yes/no question.
  Noul({super.instructions, this.criteria});

  /// Optional descriptions of the yes and no outcomes.
  final NoulCriteria? criteria;

  @override
  Map<String, Object?> toJson() => {
    'type': 'noul',
    'instructions': instructions,
    if (criteria != null) 'criteria': criteria!.toJson(),
  };

  @override
  NoulAnswer decodeAnswer(Map<String, Object?> json, String name) {
    _checkType(json, 'noul', name);
    return NoulAnswer(_requireDouble(json, 'noul', name));
  }
}

String Function(L) _defaultEncodeLabel<L extends Object>(
  Map<L, Object?> criteria,
  String kind,
) {
  final sample = criteria.keys.first;
  if (sample is String) {
    for (final label in criteria.keys) {
      if (label is! String) {
        throw TypeSafeError(
          '$kind labels must all be the same type; expected String like '
          '"$sample" but got ${label.runtimeType} ($label). Use '
          '$kind.custom to supply encodeLabel and decodeLabel for mixed or '
          'other label types.',
        );
      }
    }
    return (label) => label as String;
  }
  if (sample is Enum) {
    final sampleType = sample.runtimeType;
    for (final label in criteria.keys) {
      if (label is! Enum || label.runtimeType != sampleType) {
        throw TypeSafeError(
          '$kind labels must all be the same enum type; expected '
          '$sampleType like $sample but got ${label.runtimeType} ($label). '
          'Use $kind.custom to supply encodeLabel and decodeLabel for '
          'mixed or other label types.',
        );
      }
    }
    return (label) => (label as Enum).name;
  }
  throw TypeSafeError(
    '$kind labels must be String or enum values, got '
    '${sample.runtimeType}. Use $kind.custom to supply encodeLabel and '
    'decodeLabel for other types.',
  );
}

L Function(String) _reverseLookup<L extends Object>(
  Iterable<L> labels,
  String Function(L) encode,
) {
  final byWire = {for (final label in labels) encode(label): label};
  return (raw) {
    final label = byWire[raw];
    if (label == null) {
      throw ApiResponseValidationError(
        'the API returned label "$raw", which is not one of this question\'s '
        'criteria (${byWire.keys.join(', ')})',
      );
    }
    return label;
  };
}

/// A question that selects between named alternatives.
///
/// The label type [L] is inferred from the criteria map, so both flavors come
/// from one constructor:
///
/// ```dart
/// final tone = Choice({Tone.calm: null, Tone.angry: null});   // Choice<Tone>
/// final kind = Choice({'billing': null, 'other': null});      // Choice<String>
/// ```
final class Choice<L extends Object> extends Question<ChoiceAnswer<L>> {
  /// Creates a choice question over [criteria], mapping labels to optional
  /// descriptions.
  ///
  /// Labels must be `String` or enum values; use [Choice.custom] otherwise.
  factory Choice(Map<L, Object?> criteria, {Object? instructions}) {
    if (criteria.isEmpty) {
      throw TypeSafeError('Choice criteria must not be empty.');
    }
    final encode = _defaultEncodeLabel<L>(criteria, 'Choice');
    return Choice.custom(
      criteria: criteria,
      encodeLabel: encode,
      decodeLabel: _reverseLookup<L>(criteria.keys, encode),
      instructions: instructions,
    );
  }

  /// Creates a choice question with explicit label codecs.
  ///
  /// [encodeLabel] must be injective over [criteria]'s keys: two distinct
  /// labels that encode to the same wire string would make one of them
  /// unreachable when decoding an answer, and would silently collapse
  /// [toJson]'s criteria map to fewer entries than were supplied.
  Choice.custom({
    required Map<L, Object?> criteria,
    required this.encodeLabel,
    required this.decodeLabel,
    super.instructions,
  }) : criteria = Map.unmodifiable(criteria) {
    if (this.criteria.isEmpty) {
      throw TypeSafeError('Choice criteria must not be empty.');
    }
    final seenWireLabels = <String, L>{};
    for (final label in this.criteria.keys) {
      final wire = encodeLabel(label);
      final collidingLabel = seenWireLabels[wire];
      if (collidingLabel != null) {
        throw TypeSafeError(
          'Choice criteria labels $collidingLabel and $label both encode to '
          'the wire string "$wire"; encodeLabel must be injective.',
        );
      }
      seenWireLabels[wire] = label;
    }
  }

  /// Labels mapped to descriptions; `null` leaves a label undescribed.
  final Map<L, Object?> criteria;

  /// Converts a label to its wire string.
  final String Function(L) encodeLabel;

  /// Converts a wire string back to a label.
  final L Function(String) decodeLabel;

  L _decode(String raw, String name, String field) {
    try {
      return decodeLabel(raw);
    } on ApiResponseValidationError catch (error) {
      throw ApiResponseValidationError(
        'Question "$name": ${error.message}.',
        path: 'answers.$name.$field',
      );
    } on Object catch (error) {
      // A custom decodeLabel (from Choice.custom) may throw anything, e.g.
      // FormatException or RangeError on an unrecognized wire label. Wrap it
      // so callers only ever need to catch this SDK's error hierarchy.
      throw ApiResponseValidationError(
        'Question "$name": decodeLabel rejected the API label "$raw" '
        '($error).',
        path: 'answers.$name.$field',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'choice',
    'instructions': instructions,
    'criteria': {
      for (final entry in criteria.entries) encodeLabel(entry.key): entry.value,
    },
  };

  @override
  ChoiceAnswer<L> decodeAnswer(Map<String, Object?> json, String name) {
    _checkType(json, 'choice', name);
    final raw = json['choice'];
    if (raw is! String) {
      throw ApiResponseValidationError(
        'Question "$name" expected a string `choice`, got ${raw.runtimeType}.',
        path: 'answers.$name.choice',
      );
    }
    final probabilities = _requireMap(json, 'probabilities', name);
    return ChoiceAnswer<L>(
      choice: _decode(raw, name, 'choice'),
      confidence: _requireDouble(json, 'confidence', name),
      probabilities: {
        for (final entry in probabilities.entries)
          _decode(entry.key, name, 'probabilities'): _asDouble(
            entry.value,
            name,
            'probabilities["${entry.key}"]',
          ),
      },
    );
  }
}

/// A question that assigns a score using an ordered rubric.
///
/// Use [Score.levels] for a plain list of descriptions, or [Score.ofEnum] to
/// key the rubric by an ordered enum.
final class Score<L extends Object> extends Question<ScoreAnswer<L>> {
  Score._({
    required List<L> scale,
    required Map<L, Object?> criteria,
    super.instructions,
  }) : scale = List.unmodifiable(scale),
       criteria = Map.unmodifiable(criteria);

  /// Creates a score question from an ordered list of descriptions.
  ///
  /// Levels are the list indices, so this returns a `Score<int>`. At least
  /// two descriptions are required.
  static Score<int> levels(List<Object?> criteria, {Object? instructions}) {
    if (criteria.length < 2) {
      throw TypeSafeError(
        'Score criteria must have at least two entries, got '
        '${criteria.length}.',
      );
    }
    return Score<int>._(
      scale: List<int>.generate(criteria.length, (index) => index),
      criteria: {
        for (var index = 0; index < criteria.length; index++)
          index: criteria[index],
      },
      instructions: instructions,
    );
  }

  /// Creates a score question whose levels are enum values.
  ///
  /// Wire position comes from `Enum.index`, so the keys must form a
  /// contiguous run starting at index 0. Omitting trailing values is
  /// allowed; a gap in the middle is rejected, because it would shift every
  /// later level on the wire.
  static Score<E> ofEnum<E extends Enum>(
    Map<E, Object?> criteria, {
    Object? instructions,
  }) {
    if (criteria.length < 2) {
      throw TypeSafeError(
        'Score criteria must have at least two entries, got '
        '${criteria.length}.',
      );
    }
    final sample = criteria.keys.first;
    final sampleType = sample.runtimeType;
    for (final level in criteria.keys) {
      if (level.runtimeType != sampleType) {
        throw TypeSafeError(
          'Score.ofEnum criteria must all be the same enum type; expected '
          '$sampleType like $sample but got ${level.runtimeType} ($level).',
        );
      }
    }
    final ordered = criteria.keys.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    for (var position = 0; position < ordered.length; position++) {
      if (ordered[position].index != position) {
        throw TypeSafeError(
          'Score criteria must cover a contiguous run of enum values '
          'starting at index 0; ${ordered[position].runtimeType} index '
          '$position is missing. A gap would shift every later level on '
          'the wire.',
        );
      }
    }
    return Score<E>._(
      scale: ordered,
      criteria: {for (final level in ordered) level: criteria[level]},
      instructions: instructions,
    );
  }

  /// The levels in wire order; position equals the score index.
  final List<L> scale;

  /// Levels mapped to descriptions.
  final Map<L, Object?> criteria;

  L _levelAt(int index, String name, String field) {
    if (index < 0 || index >= scale.length) {
      throw ApiResponseValidationError(
        'Question "$name" received score level $index, outside its rubric '
        'of ${scale.length} levels.',
        path: 'answers.$name.$field',
      );
    }
    return scale[index];
  }

  Map<L, T> _byLevel<T>(
    Map<String, Object?> raw,
    String name,
    String field,
    T Function(Object? value, String key) convert,
  ) {
    final result = <L, T>{};
    for (final entry in raw.entries) {
      final index = int.tryParse(entry.key);
      if (index == null) {
        throw ApiResponseValidationError(
          'Question "$name" received the non-numeric score key '
          '"${entry.key}".',
          path: 'answers.$name.$field',
        );
      }
      result[_levelAt(index, name, field)] = convert(entry.value, entry.key);
    }
    return result;
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'score',
    'instructions': instructions,
    'criteria': [for (final level in scale) criteria[level]],
  };

  @override
  ScoreAnswer<L> decodeAnswer(Map<String, Object?> json, String name) {
    _checkType(json, 'score', name);
    return ScoreAnswer<L>(
      score: _requireDouble(json, 'score', name),
      confidence: _requireDouble(json, 'confidence', name),
      legend: _byLevel<Object?>(
        _requireMap(json, 'legend', name),
        name,
        'legend',
        (value, key) => value,
      ),
      probabilities: _byLevel<double>(
        _requireMap(json, 'probabilities', name),
        name,
        'probabilities',
        (value, key) => _asDouble(value, name, 'probabilities["$key"]'),
      ),
      scale: scale,
    );
  }
}
