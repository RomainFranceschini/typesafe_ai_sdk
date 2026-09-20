import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

enum _Tone { calm, frustrated, angry }

void main() {
  test('the public library exports everything a consumer needs', () {
    // Questions and criteria.
    expect(Noul(instructions: 'q'), isA<Question<NoulAnswer>>());
    expect(const NoulCriteria(whenTrue: 'yes'), isA<NoulCriteria>());
    expect(
      Choice({_Tone.calm: null, _Tone.angry: null}),
      isA<Question<ChoiceAnswer<_Tone>>>(),
    );
    expect(Score.levels(['low', 'high']), isA<Question<ScoreAnswer<int>>>());

    // Configuration and policy.
    expect(RetryPolicy().maxRetries, 2);
    expect(LogLevel.warn, isA<LogLevel>());
    expect(const DeveloperLogger(), isA<Logger>());
    expect(EnvVars.apiKey, 'TYPESAFE_API_KEY');
    expect(defaultBaseUrl, 'https://api.typesafe.ai');
    expect(defaultModelName, 'jev-latest');
    expect(packageVersion, isNotEmpty);

    // Errors.
    expect(ApiError.fromResponse(404, null, const {}), isA<NotFoundError>());
    expect(TypeSafeError('x'), isA<Exception>());
    expect(requestIdHeader, 'x-typesafe-request-id');
  });

  test('a full round trip works through the public API only', () async {
    final client = TypeSafeClient(
      apiKey: 'sk-test',
      baseUrl: 'https://api.example',
      httpClient: MockClient(
        (_) async => http.Response(
          '{"model":"jev-latest","usage":{"input_tokens":1,'
          '"output_tokens":2},"answers":{"tone":{"type":"choice",'
          '"choice":"calm","confidence":0.8,"probabilities":'
          '{"calm":0.8,"frustrated":0.1,"angry":0.1}}}}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final tone = Choice({
      _Tone.calm: null,
      _Tone.frustrated: null,
      _Tone.angry: null,
    }, instructions: 'Tone?');
    final response = await client.systemOne(
      state: 'all good',
      questions: {'tone': tone},
    );

    // The payoff: this is statically a _Tone, not a String.
    final _Tone picked = response.get(tone).choice;
    expect(picked, _Tone.calm);
    expect(response.usage.outputTokens, 2);

    client.close();
  });

  test('answers can be pattern-matched exhaustively', () {
    String describe(Answer answer) => switch (answer) {
      NoulAnswer(:final noul) => 'noul $noul',
      ChoiceAnswer(:final confidence) => 'choice $confidence',
      ScoreAnswer(:final score) => 'score $score',
    };
    expect(describe(const NoulAnswer(0.5)), 'noul 0.5');
  });
}
