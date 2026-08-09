import 'dart:async';

import 'package:flutter/widgets.dart';

/// Signs a forgotten session out.
///
/// The situation this exists for is ordinary in a timber yard: a phone put
/// down on a bench, or handed to someone to take a photo, while an account
/// with a customer's whole purchase history stays open on it. Nothing about
/// the app makes that obvious, so the timeout is the only thing that ends it.
///
/// Deliberately generous. A mill worker measuring a stack may not touch the
/// screen for several minutes between logs, and an app that logs them out
/// mid-count would be thrown away rather than tolerated.
class SessionTimeoutService {
  SessionTimeoutService._();

  static final SessionTimeoutService instance = SessionTimeoutService._();

  static const Duration defaultTimeout = Duration(minutes: 30);

  Duration timeout = defaultTimeout;

  /// Called when the session has been idle for [timeout]. Installed by the
  /// app shell; left null in tests that only care about the timing.
  Future<void> Function()? onTimeout;

  Timer? _timer;
  DateTime? _lastActivity;

  bool get isRunning => _timer != null;

  DateTime? get lastActivity => _lastActivity;

  /// Starts watching. Called on sign-in.
  void start() {
    _lastActivity = DateTime.now();
    _restart();
  }

  /// Any interaction at all defers the countdown.
  void recordActivity() {
    if (_timer == null) return;

    _lastActivity = DateTime.now();
    _restart();
  }

  /// Stops watching. Called on sign-out, so a signed-out app is not sitting
  /// on a timer that will fire into nothing.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer(timeout, _fire);
  }

  Future<void> _fire() async {
    _timer = null;

    final callback = onTimeout;
    if (callback == null) return;

    try {
      await callback();
    } catch (_) {
      // A failed sign-out must not leave an uncaught error on the loop; the
      // next app start will resolve the session state anyway.
    }
  }

  @visibleForTesting
  void resetForTesting() {
    stop();
    timeout = defaultTimeout;
    onTimeout = null;
    _lastActivity = null;
  }
}

/// Feeds every touch anywhere in the app into [SessionTimeoutService].
///
/// A Listener rather than a GestureDetector: it observes pointer events on
/// the way down without competing in the gesture arena, so wrapping the whole
/// app cannot swallow a tap meant for something underneath it.
class SessionActivityDetector extends StatelessWidget {
  final Widget child;

  const SessionActivityDetector({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => SessionTimeoutService.instance.recordActivity(),
      child: child,
    );
  }
}
