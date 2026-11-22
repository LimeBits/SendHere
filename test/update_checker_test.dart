import 'package:flutter_test/flutter_test.dart';
import 'package:send_here/src/update_checker.dart';

void main() {
  test('parses build number from release tag', () {
    expect(UpdateChecker.parseBuildNumber('v0.1.0-build50'), 50);
    expect(UpdateChecker.parseBuildNumber('v0.1.0-build9'), 9);
  });

  test('returns null for tags without a build number', () {
    expect(UpdateChecker.parseBuildNumber('latest'), isNull);
    expect(UpdateChecker.parseBuildNumber(''), isNull);
  });
}
