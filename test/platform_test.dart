import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/platform/platform.dart';

void main() {
  test('isBrowser is false on the VM', () {
    expect(isBrowser, isFalse);
  });

  test('describeRuntime names the Dart runtime and OS', () {
    expect(describeRuntime(), startsWith('dart/'));
    expect(describeRuntime(), contains('('));
  });

  test('readEnv returns null for a variable that is not set', () {
    expect(readEnv('TYPESAFE_DEFINITELY_NOT_SET_12345'), isNull);
  });

  test('readEnv reads and trims a set variable', () {
    // PATH is set on every platform the VM tests run on.
    final path = readEnv('PATH');
    expect(path, isNotNull);
    expect(path, path!.trim());
  });
}
