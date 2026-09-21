import 'face_scan.dart';

/// What a scan did, in numbers, for the person reading it back afterwards.
///
/// The scanner is written on a machine with no phone, so when it is tried on
/// one the only evidence of what went wrong is whatever the user remembers --
/// "it said that is the end you already scanned". That is not enough to find a
/// fault. This keeps the facts instead: how many frames arrived, how many held
/// a face, which check refused the rest and by how much, how long each frame
/// took to process, and the numbers behind every decision about the far end.
///
/// It is copied out of the app as plain text and sent back, and it costs
/// nothing to carry: a handful of counters and a short list of events.
class ScanDiagnostics {
  /// Events kept. A scan is a minute long and ten frames a second; the events
  /// are the decisions, not the frames.
  static const int maxEvents = 80;

  int framesSeen = 0;
  int framesUntracked = 0;
  int framesWithFace = 0;

  final Map<String, int> _outcomes = {};
  final Map<String, String> _lastDetail = {};
  final List<String> _events = [];

  double _processingTotalMs = 0;
  double _processingMaxMs = 0;
  int _processingSamples = 0;

  double? _firstFrameAt;
  double _lastFrameAt = 0;

  /// Frames the phone dropped because the previous one had not been answered.
  /// Reported by the screen, which is the only place that can see it.
  int framesSkipped = 0;

  void noteFrame(double time, {required bool tracked}) {
    framesSeen++;
    _firstFrameAt ??= time;
    _lastFrameAt = time;

    if (!tracked) framesUntracked++;
  }

  /// Records what one attempt at a face came to.
  void noteAttempt(FaceAttempt attempt) {
    if (attempt.isFound) {
      framesWithFace++;
      _outcomes.update('found', (n) => n + 1, ifAbsent: () => 1);
      return;
    }

    final key = attempt.rejection?.name ?? 'none';
    _outcomes.update(key, (n) => n + 1, ifAbsent: () => 1);

    final detail = attempt.detail;
    if (detail != null) _lastDetail[key] = detail;
  }

  void noteProcessing(double milliseconds) {
    _processingSamples++;
    _processingTotalMs += milliseconds;
    if (milliseconds > _processingMaxMs) _processingMaxMs = milliseconds;
  }

  void noteEvent(String text) {
    final started = _firstFrameAt;
    final at = started == null ? 0.0 : _lastFrameAt - started;

    _events.add('${at.toStringAsFixed(1)}s  $text');
    if (_events.length > maxEvents) _events.removeAt(0);
  }

  double get averageProcessingMs =>
      _processingSamples == 0 ? 0 : _processingTotalMs / _processingSamples;

  double get maxProcessingMs => _processingMaxMs;

  /// Frames per second over the scan so far.
  double get framesPerSecond {
    final started = _firstFrameAt;
    if (started == null || _lastFrameAt <= started) return 0;
    return framesSeen / (_lastFrameAt - started);
  }

  double get faceShare => framesSeen == 0 ? 0 : framesWithFace / framesSeen;

  /// The whole report, as text. [context] is the session's own account of
  /// where it got to; everything else is counted here.
  String report({List<String> context = const []}) {
    final b = StringBuffer();

    b.writeln('SmartLog scan report');
    b.writeln('');

    for (final line in context) {
      b.writeln(line);
    }

    b.writeln('');
    b.writeln('Frames');
    b.writeln('  received      $framesSeen  '
        '(${framesPerSecond.toStringAsFixed(1)} per second)');
    b.writeln('  skipped       $framesSkipped');
    b.writeln('  untracked     $framesUntracked');
    b.writeln('  with a face   $framesWithFace  '
        '(${(faceShare * 100).toStringAsFixed(0)}%)');
    b.writeln('  processing    ${averageProcessingMs.toStringAsFixed(1)} ms '
        'average, ${maxProcessingMs.toStringAsFixed(1)} ms worst');

    if (_outcomes.isNotEmpty) {
      b.writeln('');
      b.writeln('What each frame came to');

      final ordered = _outcomes.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      for (final e in ordered) {
        final detail = _lastDetail[e.key];
        b.writeln('  ${e.key.padRight(20)} ${e.value}'
            '${detail == null ? '' : '   (last: $detail)'}');
      }
    }

    if (_events.isNotEmpty) {
      b.writeln('');
      b.writeln('Events');
      for (final event in _events) {
        b.writeln('  $event');
      }
    }

    return b.toString();
  }
}
