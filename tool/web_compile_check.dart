// Compile-only check that the package builds for web:
//   dart compile js -o <out>.js tool/web_compile_check.dart
// Not part of the public API and not shipped.
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

void main() {
  // Referencing the client is enough to pull in every transitive import.
  final client = TypeSafeClient(
    apiKey: 'compile-check',
    dangerouslyAllowBrowser: true,
  );
  client.close();
}
