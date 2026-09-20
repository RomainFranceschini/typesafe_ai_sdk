@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

enum Category { billing, technical, other }

void main() {
  final apiKey = Platform.environment['TYPESAFE_API_KEY'];
  final skip = apiKey == null || apiKey.trim().isEmpty
      ? 'TYPESAFE_API_KEY is not set; skipping live API tests.'
      : null;

  group('live API', () {
    late TypeSafeClient client;

    setUp(() => client = TypeSafeClient());
    tearDown(() => client.close());

    test('lists models', () async {
      final models = await client.models.list();
      expect(models, isNotEmpty);
      expect(models.first.name, isNotEmpty);
    });

    test('answers a choice question with an enum label', () async {
      final category = Choice({
        Category.billing: null,
        Category.technical: null,
        Category.other: null,
      }, instructions: 'What is this ticket about?');

      final response = await client.systemOne(
        state: {'document': 'I was charged twice. Please fix this ASAP.'},
        questions: {'category': category},
      );

      final answer = response.get(category);
      expect(answer.choice, isIn(Category.values));
      expect(answer.probabilities.keys, containsAll(Category.values));
      expect(
        answer.probabilities.values,
        everyElement(allOf(greaterThanOrEqualTo(0), lessThanOrEqualTo(1))),
      );
      expect(answer.confidence, inInclusiveRange(0, 1));
      expect(response.requestId, isNotNull);
    });

    test('answers noul and score questions', () async {
      final billing = Noul(instructions: 'Is this about billing?');
      final urgency = Score.levels([
        'can wait',
        'this week',
        'today',
        'right now',
      ], instructions: 'How urgent is this?');

      final response = await client.systemOne(
        state: 'I was charged twice and I need this fixed right now.',
        questions: {'billing': billing, 'urgency': urgency},
      );

      expect(response.get(billing).noul, inInclusiveRange(0, 1));
      expect(response.get(urgency).score, inInclusiveRange(0, 3));
      expect(response.get(urgency).legend, isNotEmpty);
    });

    test('raises AuthenticationError for a bad key', () async {
      final bad = TypeSafeClient(apiKey: 'sk-definitely-invalid');
      addTearDown(bad.close);
      await expectLater(
        bad.systemOne(state: 'x', questions: {'q': Noul()}),
        throwsA(isA<AuthenticationError>()),
      );
    });
  }, skip: skip);
}
