import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/local_db.dart';
import 'cloud_restore_service.dart';
import 'cloud_sync_engine.dart';
import 'session_timeout_service.dart';

/// Decides what should happen when someone signs in.
///
/// Kept apart from [CloudSyncEngine], which only knows how to get queued work
/// to the cloud, because the interesting decisions here are about *policy* --
/// when to restore, when to sweep everything up -- and policy is the part
/// worth being able to test on its own.
class CloudSyncCoordinator {
  CloudSyncCoordinator({
    CloudSyncEngine? engine,
    CloudRestoreService? restore,
  })  : _engine = engine ?? CloudSyncEngine.instance,
        _restore = restore ?? CloudRestoreService.instance;

  static final CloudSyncCoordinator instance = CloudSyncCoordinator();

  final CloudSyncEngine _engine;
  final CloudRestoreService _restore;

  StreamSubscription<User?>? _authSubscription;

  /// One backfill per account per device. Recorded so a user with two
  /// thousand logs is not re-uploaded from scratch every time they open the
  /// app -- ordinary edits keep the cloud current after the first sweep.
  static String _backfillKey(String uid) => "cloud_backfilled_$uid";

  /// Starts watching for sign-in. Safe to call once at startup.
  void start() {
    _authSubscription?.cancel();

    try {
      _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
        (user) {
          if (user == null) {
            // Signing out leaves the local database exactly as it is: the
            // phone is the source of truth, and nobody should lose a day's
            // measuring by tapping the wrong button.
            //
            // The idle timer does stop, so a signed-out app is not sitting
            // on a countdown that will fire into nothing.
            SessionTimeoutService.instance.stop();
            return;
          }

          SessionTimeoutService.instance.start();
          unawaited(onSignedIn(user.uid));
        },
      );
    } catch (_) {
      // Firebase not initialised (widget tests). Syncing is simply off.
    }
  }

  /// Restores if there is nothing here, sweeps everything up once, then
  /// drains.
  Future<RestoreOutcome> onSignedIn(String uid) async {
    var outcome = const RestoreOutcome();

    try {
      // Order matters. Restoring first means a fresh install pulls its data
      // down *before* the backfill sweep runs, so the sweep re-queues the
      // restored rows against the cloud ids they arrived with rather than
      // uploading a second copy of everything.
      outcome = await _restore.restoreIfLocalIsEmpty();
    } catch (_) {
      // A failed restore must not stop the upload half from working.
    }

    await _backfillOnce(uid);
    await _engine.drain();

    return outcome;
  }

  Future<void> _backfillOnce(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (prefs.getBool(_backfillKey(uid)) ?? false) return;

      // Everything already on this phone, including everything saved during
      // the long stretch when the security rules were rejecting all of it.
      await _engine.queueEverything();

      await prefs.setBool(_backfillKey(uid), true);
    } catch (_) {}
  }

  /// Re-queues every row regardless of whether a backfill has run before.
  /// Behind an explicit user action, because on a large database it is a lot
  /// of writes.
  Future<int> backUpEverythingNow() => _engine.queueEverything();

  /// True when a restore would overwrite nothing.
  Future<bool> get canRestoreSafely => LocalDB.isEmpty();

  @visibleForTesting
  Future<void> stop() async {
    await _authSubscription?.cancel();
    _authSubscription = null;
  }
}
