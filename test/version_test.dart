import 'dart:io';

import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/src/version.dart';

void main() {
  test('packageVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no version field');
    expect(packageVersion, match!.group(1));
  });
}
