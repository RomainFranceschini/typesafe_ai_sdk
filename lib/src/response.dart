/// The System One response, its metadata, and typed answer lookup.
library;

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'answers.dart';
import 'errors.dart';
import 'questions.dart';

/// Token counts for a request, when the API reports them.
final class Usage {
  /// Creates token counts.
  const Usage({this.inputTokens, this.outputTokens});

  /// Builds usage from its wire form.
  ///
  /// A missing, `null`, or non-numeric value yields `null` for that field
  /// rather than throwing: the API does not always report usage, and a
  /// malformed usage block should not fail the whole response.
  factory Usage.fromJson(Map<String, Object?> json) {
    final input = json['input_tokens'];
    final output = json['output_tokens'];
    return Usage(
      inputTokens: input is num ? input.toInt() : null,
      outputTokens: output is num ? output.toInt() : null,
    );
  }

  /// Input tokens used, or `null` when the API did not report it.
  final int? inputTokens;

  /// Output tokens used, or `null` when the API did not report it.
  final int? outputTokens;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Usage &&
          inputTokens == other.inputTokens &&
          outputTokens == other.outputTokens;

  @override
  int get hashCode => Object.hash(inputTokens, outputTokens);

  @override
  String toString() =>
      'Usage(inputTokens: $inputTokens, outputTokens: $outputTokens)';
}

/// Answers to a System One request, with model and usage metadata.
final class SystemOneResponse {
  SystemOneResponse._({
    required this.model,
    required this.answers,
    required this.usage,
    required this.requestId,
    required this.httpResponse,
    required this._namesByQuestion,
  });

  /// The model that answered the request.
  final String model;

  /// Every decoded answer, keyed by question name.
  ///
  /// Use [get] for statically typed access. This map is the escape hatch for
  /// question sets built dynamically, where no handle is available.
  final Map<String, Answer> answers;

  /// Token usage for the request.
  final Usage usage;

  /// The API's request identifier, when it sent one.
  final String? requestId;

  /// The underlying HTTP response, with its body already read.
  ///
  /// Read the payload from `httpResponse.bodyBytes`, not `httpResponse.body`:
  /// the `body` getter parses the `Content-Type` header and throws a
  /// [FormatException] on a value it cannot fully consume — for example the
  /// duplicate `Content-Type` headers some proxies emit, which HTTP clients
  /// join with `, ` into a single invalid value. This SDK reads the bytes
  /// everywhere for that reason.
  final http.Response httpResponse;

  final Map<Question<Answer>, List<String>> _namesByQuestion;

  /// The answer to [question], typed by the question that produced it.
  ///
  /// Questions are matched by identity, so the handle passed here must be the
  /// same instance that was passed in the request.
  ///
  /// Throws [ArgumentError] when [question] was not part of the request, was
  /// registered under more than one name, or produced no usable answer (for
  /// example, because the API returned an answer type this SDK version does
  /// not recognize, which is dropped rather than raised).
  A get<A extends Answer>(Question<A> question) {
    final names = _namesByQuestion[question];
    if (names == null) {
      throw ArgumentError.value(
        question,
        'question',
        'This question was not part of the request. Pass the same instance '
            'that was used in `questions`, or read `answers` by name.',
      );
    }
    if (names.length > 1) {
      throw ArgumentError.value(
        question,
        'question',
        'This question was registered under ${names.length} names '
            '(${names.join(', ')}), so the answer is ambiguous. Read '
            '`answers` by name instead.',
      );
    }
    final answer = answers[names.single];
    if (answer == null) {
      throw ArgumentError.value(
        question,
        'question',
        'The API returned no usable answer for "${names.single}".',
      );
    }
    return answer as A;
  }
}

/// Decodes a System One response body against the questions that produced it.
///
/// Answers whose `type` this SDK version does not recognize, and answers no
/// question asked for, are dropped with a warning rather than failing the
/// whole response. The raw payload remains available through
/// [SystemOneResponse.httpResponse] (read its `bodyBytes`).
SystemOneResponse decodeSystemOne({
  required Object? body,
  required Map<String, Question<Answer>> questions,
  required http.Response httpResponse,
  required Logger logger,
}) {
  if (body is! Map) {
    throw ApiResponseValidationError(
      'Expected a JSON object from /v1/systemone, got ${body.runtimeType}.',
    );
  }
  final decoded = body.cast<String, Object?>();

  final model = decoded['model'];
  if (model is! String) {
    throw ApiResponseValidationError(
      'Expected a string `model`, got ${model.runtimeType}.',
      path: 'model',
    );
  }

  final rawUsage = decoded['usage'];
  final usage = rawUsage is Map
      ? Usage.fromJson(rawUsage.cast<String, Object?>())
      : const Usage();

  final rawAnswers = decoded['answers'];
  // Validated like `model` above: a missing or non-object `answers` is a
  // malformed payload, and accepting it silently would surface much later as
  // an `ArgumentError` from `get()` blaming the caller's question handle.
  if (rawAnswers is! Map) {
    throw ApiResponseValidationError(
      'Expected an object `answers`, got ${rawAnswers.runtimeType}.',
      path: 'answers',
    );
  }
  final answers = <String, Answer>{};
  for (final entry in rawAnswers.cast<String, Object?>().entries) {
    final name = entry.key;
    final raw = entry.value;
    if (raw is! Map) {
      throw ApiResponseValidationError(
        'Expected answer "$name" to be an object, got ${raw.runtimeType}.',
        path: 'answers.$name',
      );
    }
    final answer = raw.cast<String, Object?>();
    final type = answer['type'];
    if (type is! String) {
      throw ApiResponseValidationError(
        'Answer "$name" has no string `type`.',
        path: 'answers.$name.type',
      );
    }
    if (!knownAnswerTypes.contains(type)) {
      logger.warning(
        'Ignoring answer "$name" with unrecognized type "$type". Upgrade '
        'the SDK to read it, or use httpResponse.bodyBytes for the raw '
        'payload.',
      );
      continue;
    }
    final question = questions[name];
    if (question == null) {
      logger.warning('Ignoring answer "$name", which no question requested.');
      continue;
    }
    answers[name] = question.decodeAnswer(answer, name);
  }

  final namesByQuestion = Map<Question<Answer>, List<String>>.identity();
  for (final entry in questions.entries) {
    namesByQuestion.putIfAbsent(entry.value, () => <String>[]).add(entry.key);
  }

  return SystemOneResponse._(
    model: model,
    answers: Map.unmodifiable(answers),
    usage: usage,
    requestId: httpResponse.headers[requestIdHeader],
    httpResponse: httpResponse,
    namesByQuestion: namesByQuestion,
  );
}
