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
| `timeout` | — | 10 s per attempt |
| `retry` | — | 2 retries, 500 ms to 5 s backoff |

Explicit values beat environment variables, which beat defaults.

Call `client.close()` when finished. If you pass your own `httpClient`,
closing it is yours to do.

## Logging

The SDK logs through [`package:logging`][logging] under the logger named
`typesafe_ai_sdk`, with `.transport` and `.response` children. Like any
well-behaved library it installs no handler, so it prints nothing until your
application attaches one:

```dart
import 'package:logging/logging.dart';

Logger.root.level = Level.INFO;
Logger.root.onRecord.listen((record) {
  print('${record.level.name}: ${record.loggerName}: ${record.message}');
});
```

`Level.INFO` carries one line per request with its status, elapsed time, and
request ID. `Level.FINE` adds the full URL, headers, and bodies; credential
headers (`Authorization`, `X-Api-Key`, `Cookie`, and friends) are masked, but
bodies are not, so avoid `FINE` where the transcript is untrusted.

Pass `logger:` to `TypeSafeClient` to place the SDK's records under a logger of
your own instead:

```dart
final client = TypeSafeClient(logger: Logger('myapp.typesafe'));
```

[logging]: https://pub.dev/packages/logging

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

## AI disclosure

This project was developed with substantial assistance from AI coding tools.
Generated code has been reviewed, tested, and is maintained by a human.
Please report any issues through the issue tracker.

## Contributing

```sh
dart pub get
dart format .
dart analyze
dart test                                   # unit tests
TYPESAFE_API_KEY=... dart test test/integration/   # live API tests
TMP_DIR=$(mktemp -d) && dart compile js -o "$TMP_DIR/out.js" tool/web_compile_check.dart && rm -rf "$TMP_DIR"   # web build check
```
