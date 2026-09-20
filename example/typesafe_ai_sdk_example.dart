// Run with: dart run example/typesafe_ai_sdk_example.dart
// Requires TYPESAFE_API_KEY in the environment.
import 'package:logging/logging.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

enum Tone { calm, frustrated, angry }

enum Urgency { canWait, thisWeek, today, rightNow }

Future<void> main() async {
  // The SDK logs nothing until you attach a handler. Raise the level to
  // Level.ALL to see full request and response detail.
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.loggerName}: ${record.message}');
  });

  final client = TypeSafeClient();

  try {
    final models = await client.models.list();
    print('Available models: ${models.map((m) => m.name).join(', ')}');

    final ticket = {
      'subject': 'Charged twice this month',
      'body':
          'Hi, I see two charges of \$49 on my card for August. I only '
          'have one account. Please fix this ASAP, I am pretty frustrated.',
    };

    // Bind each question to a variable so answers can be looked up by handle.
    final isBilling = Noul(instructions: 'Is this ticket about billing?');
    final tone = Choice({
      Tone.calm: null,
      Tone.frustrated: null,
      Tone.angry: null,
    }, instructions: "What is the customer's tone?");
    final urgency = Score.ofEnum({
      Urgency.canWait: 'can wait',
      Urgency.thisWeek: 'this week',
      Urgency.today: 'today',
      Urgency.rightNow: 'right now',
    }, instructions: 'How urgent is this ticket?');
    final refundRisk = Score.levels([
      'unlikely',
      'possible',
      'likely',
    ], instructions: 'How likely is the customer to demand a refund?');

    final response = await client.systemOne(
      state: ticket,
      questions: {
        'isBilling': isBilling,
        'tone': tone,
        'urgency': urgency,
        'refundRisk': refundRisk,
      },
    );

    // Every answer is typed by the question that produced it.
    final billingAnswer = response.get(isBilling);
    final toneAnswer = response.get(tone);
    final urgencyAnswer = response.get(urgency);
    final refundAnswer = response.get(refundRisk);

    print('billing?     ${billingAnswer.noul.toStringAsFixed(2)}');
    print(
      'tone         ${toneAnswer.choice.name} '
      '(${toneAnswer.probabilities[toneAnswer.choice]!.toStringAsFixed(2)})',
    );
    print(
      'urgency      ${urgencyAnswer.score.toStringAsFixed(2)} '
      '-> ${urgencyAnswer.nearestLevel.name}',
    );
    print(
      'refund risk  ${refundAnswer.score.toStringAsFixed(2)} '
      '(${refundAnswer.confidence.toStringAsFixed(2)} confidence)',
    );
    print(
      'tokens       ${response.usage.inputTokens} in / '
      '${response.usage.outputTokens} out',
    );
  } on ApiError catch (error) {
    print(
      'API error ${error.statusCode} '
      '(request ${error.requestId ?? 'unknown'}): ${error.body}',
    );
  } finally {
    client.close();
  }
}
