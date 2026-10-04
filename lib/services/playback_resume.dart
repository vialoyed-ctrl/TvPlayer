Duration playbackStartPosition({
  required Duration? resume,
  required Duration duration,
  required int skipIntroSeconds,
  required int skipOutroSeconds,
  required Duration tailReserve,
}) {
  var start = resume ?? Duration(seconds: skipIntroSeconds);
  if (start < Duration.zero) start = Duration.zero;
  if (duration <= Duration.zero) return start;
  if (resume == null &&
      duration <= Duration(seconds: skipIntroSeconds + skipOutroSeconds + 10)) {
    return Duration.zero;
  }
  final latest = duration - tailReserve - const Duration(milliseconds: 1);
  if (latest <= Duration.zero) return Duration.zero;
  if (start > latest) return resume == null ? Duration.zero : latest;
  return start;
}
