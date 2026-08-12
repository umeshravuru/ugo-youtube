/// Where playback should resume for a video watched up to [lastPositionMs].
///
/// Starts over when barely watched (< 5s) or when effectively finished
/// (≥ 95% of a known duration).
Duration computeResumeOffset({
  required int lastPositionMs,
  required int durationMs,
}) {
  if (lastPositionMs < 5000) return Duration.zero;
  if (durationMs > 0 && lastPositionMs >= (durationMs * 0.95).round()) {
    return Duration.zero;
  }
  return Duration(milliseconds: lastPositionMs);
}
