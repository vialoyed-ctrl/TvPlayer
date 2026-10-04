import 'package:flutter_test/flutter_test.dart';
import 'package:tvplayer/services/playback_watchdog.dart';

void main() {
  test('detects a stall even when the player stops sending callbacks', () {
    final watchdog = PlaybackWatchdog();
    bool check(int second) => watchdog.check(
      now: Duration(seconds: second),
      position: const Duration(minutes: 40),
      enabled: true,
    );
    expect(check(0), false);
    expect(check(19), false);
    expect(check(20), true);
  });
  test('regular progress keeps long playback healthy', () {
    final watchdog = PlaybackWatchdog();
    for (var second = 0; second < 7200; second += 2) {
      expect(
        watchdog.check(
          now: Duration(seconds: second),
          position: Duration(seconds: second),
          enabled: true,
        ),
        false,
      );
    }
  });
  test('pause, background, loading and seeking reset the grace period', () {
    final watchdog = PlaybackWatchdog();
    bool check(int second, bool enabled) => watchdog.check(
      now: Duration(seconds: second),
      position: const Duration(minutes: 40),
      enabled: enabled,
    );
    expect(check(0, true), false);
    expect(check(19, true), false);
    expect(check(500, false), false);
    expect(check(600, true), false);
    expect(check(619, true), false);
    expect(check(620, true), true);
  });
  test('backward seek and reconnection grant a fresh grace period', () {
    final watchdog = PlaybackWatchdog();
    expect(
      watchdog.check(
        now: Duration.zero,
        position: const Duration(minutes: 40),
        enabled: true,
      ),
      false,
    );
    expect(
      watchdog.check(
        now: const Duration(seconds: 19),
        position: const Duration(minutes: 20),
        enabled: true,
      ),
      false,
    );
    expect(
      watchdog.check(
        now: const Duration(seconds: 20),
        position: const Duration(minutes: 20),
        enabled: true,
      ),
      false,
    );
    watchdog.reset();
    expect(
      watchdog.check(
        now: const Duration(seconds: 100),
        position: const Duration(minutes: 20),
        enabled: true,
      ),
      false,
    );
  });
}
