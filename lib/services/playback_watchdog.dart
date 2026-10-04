/// Detects stalled playback independently of player callbacks.
class PlaybackWatchdog {
  PlaybackWatchdog({this.timeout = const Duration(seconds: 20)});
  final Duration timeout;
  Duration? _position;
  Duration? _lastProgressAt;

  void reset() {
    _position = null;
    _lastProgressAt = null;
  }

  bool check({
    required Duration now,
    required Duration position,
    required bool enabled,
  }) {
    if (!enabled) {
      reset();
      return false;
    }
    if (_position == null || position != _position) {
      _position = position;
      _lastProgressAt = now;
      return false;
    }
    return now - _lastProgressAt! >= timeout;
  }
}
