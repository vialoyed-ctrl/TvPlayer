import 'package:flutter_test/flutter_test.dart';
import 'package:tvplayer/services/playback_resume.dart';

void main() {
  Duration start(Duration? resume, {int seconds = 3600}) =>
      playbackStartPosition(
        resume: resume,
        duration: Duration(seconds: seconds),
        skipIntroSeconds: 90,
        skipOutroSeconds: 90,
        tailReserve: const Duration(seconds: 2),
      );
  test(
    'reconnection preserves a breakpoint within the intro and short playlists',
    () {
      expect(start(const Duration(seconds: 15)), const Duration(seconds: 15));
      expect(
        start(const Duration(seconds: 40), seconds: 120),
        const Duration(seconds: 40),
      );
      expect(start(Duration.zero), Duration.zero);
    },
  );
  test(
    'fresh playback still skips intros only for sufficiently long episodes',
    () {
      expect(start(null), const Duration(seconds: 90));
      expect(start(null, seconds: 120), Duration.zero);
    },
  );
  test(
    'a shorter refreshed stream clamps near the end rather than restarting',
    () {
      expect(
        start(const Duration(seconds: 200), seconds: 120),
        const Duration(milliseconds: 117999),
      );
    },
  );
  test('unknown duration preserves the breakpoint', () {
    expect(
      start(const Duration(minutes: 40), seconds: 0),
      const Duration(minutes: 40),
    );
  });
}
