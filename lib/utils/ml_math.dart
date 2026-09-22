import 'dart:math' as math;

/// Softmax: turns a row of logits into probabilities that sum to one.
///
/// Kept as a small, standalone piece of arithmetic rather than folded into
/// any one detector, because it is generic to any model that might end up
/// wired into [DefectDetector] and does not belong to whichever one happens
/// to be installed today.
List<double> softmax(List<double> logits) {
  if (logits.isEmpty) return const [];

  final peak = logits.reduce(math.max);

  final exponentials = [for (final v in logits) math.exp(v - peak)];
  final total = exponentials.reduce((a, b) => a + b);

  if (total <= 0) return List<double>.filled(logits.length, 0);

  return [for (final e in exponentials) e / total];
}
