# typesafe_ai_sdk

An **unofficial** Dart SDK for [TypeSafe AI](https://typesafe.ai), ported from
the official [JavaScript SDK](https://github.com/typesafe-ai/typesafe-sdk-js)
(v0.6.0). Not affiliated with or endorsed by TypeSafe AI. The official SDKs are
[JavaScript/TypeScript](https://github.com/typesafe-ai/typesafe-sdk-js) and
[Python](https://github.com/typesafe-ai/typesafe-sdk-python).

## Quickstart

```sh
dart pub add typesafe_ai_sdk
```

Set `TYPESAFE_API_KEY` in your environment, then:

```dart
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

enum Category { billing, technical, other }

Future<void> main() async {
  final client = TypeSafeClient();

  final category = Choice(
    {Category.billing: null, Category.technical: null, Category.other: null},
    instructions: 'What is this ticket about?',
  );

  final response = await client.systemOne(
    state: {'document': 'I was charged twice. Please fix this ASAP.'},
    questions: {'category': category},
  );

  // Statically a Category, not a String.
  print(response.get(category).choice);

  client.close();
}
```

## Typed answers

Bind each question to a variable, then look its answer up by that handle.
`get` returns the exact type the question produces:

```dart
final isBilling = Noul(instructions: 'Is this about billing?');
final urgency = Score.levels(['can wait', 'today', 'right now']);

final response = await client.systemOne(state: ticket, questions: {
  'isBilling': isBilling,
  'urgency': urgency,
});

response.get(isBilling).noul;          // double
response.get(urgency).score;           // double
response.get(urgency).nearestLevel;    // int
response.answers['isBilling'];         // Answer, for dynamic question sets
```

Choice and score labels can be Dart enums, which the official SDKs cannot do.
`Score.ofEnum` takes its wire order from `Enum.index`.

## Configuration

| Option | Environment variable | Default |
|---|---|---|
| `apiKey` | `TYPESAFE_API_KEY` | required |
| `baseUrl` | `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` |
| `defaultModel` | `TYPESAFE_DEFAULT_MODEL` | `jev-latest` |
| `logLevel` | `TYPESAFE_LOG_LEVEL` | `warn` |
| `timeout` | — | 10 s per attempt |
| `retry` | — | 2 retries, 500 ms to 5 s backoff |

Explicit values beat environment variables, which beat defaults.

Call `client.close()` when finished. If you pass your own `httpClient`,
closing it is yours to do.

## Platform support

Works on the Dart VM, Flutter mobile and desktop, and the web.

Browser use is refused by default, because it exposes your API key to anyone
who loads the page. Pass `dangerouslyAllowBrowser: true` only if you
understand that. On web there are no environment variables, so `apiKey` must be
passed explicitly, and the API must allow the `X-TypeSafe-*` headers through
CORS preflight.

## Differences from the official SDKs

- Answers are looked up by question handle rather than inferred from an object
  literal, because Dart has no mapped types.
- Choice and score labels may be enums.
- No request cancellation; timeouts and retries bound every request.
- `Duration` replaces millisecond integers throughout.

## License

MIT
