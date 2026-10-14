import 'package:flutter_test/flutter_test.dart';
import 'package:siegel/app_lock.dart';

void main() {
  test('shouldLock (ID-15)', () {
    final now = DateTime(2026, 10, 15, 12);
    DateTime ago(int s) => now.subtract(Duration(seconds: s));
    expect(shouldLock(timeout: null, leftAt: null, now: now), isFalse, reason: 'lock off');
    expect(shouldLock(timeout: 60, leftAt: null, now: now), isTrue, reason: 'cold start');
    expect(shouldLock(timeout: 60, leftAt: ago(59), now: now), isFalse);
    expect(shouldLock(timeout: 60, leftAt: ago(60), now: now), isTrue);
    expect(
      shouldLock(timeout: 0, leftAt: ago(0), now: now),
      isTrue,
      reason: 'immediately',
    );
  });
}
