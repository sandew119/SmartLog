import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Why the last cloud backup attempt ended the way it did.
enum CloudSyncState {
  /// Nothing has been attempted yet this session.
  idle,

  /// Signed out. Cloud backup is off by design, not broken.
  signedOut,

  /// The last push reached Firestore.
  ok,

  /// The last push did not.
  failed,
}

@immutable
class CloudSyncSnapshot {
  final CloudSyncState state;

  /// Plain English, safe to put in front of a user. Null unless [state] is
  /// [CloudSyncState.failed].
  final String? message;

  /// The underlying Firebase error code, for a developer reading logs.
  final String? code;

  final DateTime? lastSuccess;
  final DateTime? lastFailure;

  /// How many pushes have failed in a row. One failure is a bad moment on a
  /// train; twenty in a row is a broken configuration.
  final int consecutiveFailures;

  const CloudSyncSnapshot({
    this.state = CloudSyncState.idle,
    this.message,
    this.code,
    this.lastSuccess,
    this.lastFailure,
    this.consecutiveFailures = 0,
  });

  /// True once the failures look systematic rather than incidental.
  ///
  /// The threshold exists so a single push failed in a tunnel never nags
  /// anyone, while a rules misconfiguration -- which fails *every* time --
  /// surfaces almost immediately.
  bool get isPersistentlyFailing =>
      state == CloudSyncState.failed && consecutiveFailures >= 3;
}

/// Records whether the one-way cloud mirror is actually working.
///
/// Every Firestore call in this app is deliberately allowed to fail without
/// disturbing the user: the phone's SQLite database is the source of truth
/// and a backup that cannot be written is not a reason to block a sale being
/// recorded in a timber yard with no signal.
///
/// What that cost, before this existed, was any way to tell a bad afternoon
/// of signal apart from a backup that had *never once worked*. The security
/// rules only granted access to `users/{uid}` -- and Firestore rules do not
/// cascade into subcollections -- so every stack and every log was rejected,
/// silently, by a `catch (_) {}`. Swallowing the error is still right. Not
/// noticing it was not.
class CloudSyncStatus {
  CloudSyncStatus._();

  static final CloudSyncStatus instance = CloudSyncStatus._();

  final ValueNotifier<CloudSyncSnapshot> _snapshot =
      ValueNotifier(const CloudSyncSnapshot());

  ValueListenable<CloudSyncSnapshot> get listenable => _snapshot;

  CloudSyncSnapshot get current => _snapshot.value;

  void recordSignedOut() {
    final previous = _snapshot.value;

    _snapshot.value = CloudSyncSnapshot(
      state: CloudSyncState.signedOut,
      lastSuccess: previous.lastSuccess,
      lastFailure: previous.lastFailure,
    );
  }

  void recordSuccess() {
    final previous = _snapshot.value;

    _snapshot.value = CloudSyncSnapshot(
      state: CloudSyncState.ok,
      lastSuccess: DateTime.now(),
      lastFailure: previous.lastFailure,
    );
  }

  void recordFailure(Object error, {String? operation}) {
    final previous = _snapshot.value;
    final code = error is FirebaseException ? error.code : null;

    // Visible in `flutter run` output straight away, which is where a
    // developer looks first and where nothing appeared before.
    debugPrint(
      "Cloud backup failed"
      "${operation == null ? '' : ' during $operation'}"
      "${code == null ? '' : ' [$code]'}: $error",
    );

    _snapshot.value = CloudSyncSnapshot(
      state: CloudSyncState.failed,
      message: describe(error),
      code: code,
      lastSuccess: previous.lastSuccess,
      lastFailure: DateTime.now(),
      consecutiveFailures: previous.state == CloudSyncState.failed
          ? previous.consecutiveFailures + 1
          : 1,
    );
  }

  /// Turns a Firebase error into something a sawmill owner can act on.
  ///
  /// The distinction that matters is "your signal is bad, it will sort
  /// itself out" versus "this will never work until somebody changes a
  /// setting", because only one of those is worth interrupting anyone for.
  static String describe(Object error) {
    if (error is! FirebaseException) {
      return "Backup to the cloud didn't go through. Your logs are still "
          "saved on this phone.";
    }

    return switch (error.code) {
      "permission-denied" =>
        "The cloud database is refusing this backup. Your logs are safe on "
            "this phone, but nothing is being backed up. This needs the "
            "Firestore security rules fixed — it will not fix itself.",
      "unauthenticated" =>
        "Your sign-in has expired. Sign in again to start backing up.",
      "unavailable" ||
      "network-request-failed" ||
      "deadline-exceeded" =>
        "No connection to the cloud right now. Your logs are saved on this "
            "phone and will need backing up when you're online.",
      "resource-exhausted" =>
        "The cloud database has hit its usage limit. Your logs are safe on "
            "this phone.",
      _ => "Backup to the cloud didn't go through (${error.code}). Your logs "
          "are still saved on this phone.",
    };
  }

  /// Test seam: the singleton outlives any one test otherwise.
  @visibleForTesting
  void resetForTesting() {
    _snapshot.value = const CloudSyncSnapshot();
  }
}
