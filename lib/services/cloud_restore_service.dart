import 'package:firebase_auth/firebase_auth.dart';

import '../database/local_db.dart';
import 'cloud_transport.dart';
import 'user_preferences_service.dart';

class RestoreOutcome {
  final int stacks;
  final int logs;
  final bool settingsRestored;

  const RestoreOutcome({
    this.stacks = 0,
    this.logs = 0,
    this.settingsRestored = false,
  });

  bool get restoredAnything => stacks > 0 || logs > 0 || settingsRestored;
}

/// Brings a user's data back down onto a phone that does not have it.
///
/// The case this exists for is the one that makes a backup worth having: a
/// lost phone, a broken phone, a reinstall. It is deliberately *not* a merge
/// -- it will not run over a database that already has work in it, because
/// deciding which of two versions of a stack wins is a question only the user
/// can answer, and guessing wrong destroys someone's day of measuring.
class CloudRestoreService {
  CloudRestoreService({CloudTransport? transport, String? Function()? uid})
      : _transport = transport ?? const FirestoreCloudTransport(),
        _uidReader = uid ?? _firebaseUid;

  static final CloudRestoreService instance = CloudRestoreService();

  final CloudTransport _transport;
  final String? Function() _uidReader;

  static String? _firebaseUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  /// Restores only when this phone has nothing to lose.
  ///
  /// Called on sign-in, so a fresh install gets its data back without anyone
  /// having to know the feature exists.
  Future<RestoreOutcome> restoreIfLocalIsEmpty() async {
    if (!await LocalDB.isEmpty()) return const RestoreOutcome();

    return restore();
  }

  /// Downloads everything and writes it locally.
  ///
  /// Callers other than [restoreIfLocalIsEmpty] are responsible for having
  /// asked the user first.
  Future<RestoreOutcome> restore() async {
    final uid = _uidReader();
    if (uid == null) return const RestoreOutcome();

    final snapshot = await _transport.downloadAll(uid);

    var restoredLogs = 0;

    for (final stack in snapshot.stacks) {
      final cloudId = stack["cloudId"] as String?;

      final localStackId = await LocalDB.insertRestoredStack(stack);

      // Logs are written under the *new* local id their parent just got,
      // while keeping the cloud id they arrived with. Getting this wrong is
      // how a restore silently reparents someone's timber into the wrong
      // customer's stack.
      for (final log in snapshot.logsByStack[cloudId] ?? const []) {
        await LocalDB.insertRestoredLog(log, stackId: localStackId);
        restoredLogs++;
      }
    }

    for (final log in snapshot.standaloneLogs) {
      await LocalDB.insertRestoredLog(log);
      restoredLogs++;
    }

    final settings = snapshot.settings;
    var settingsRestored = false;

    if (settings != null) {
      settingsRestored =
          await UserPreferencesService.instance.adoptFromCloud(settings);
    }

    return RestoreOutcome(
      stacks: snapshot.stacks.length,
      logs: restoredLogs,
      settingsRestored: settingsRestored,
    );
  }

  /// What is waiting in the cloud, so the user can be told what a restore
  /// would bring back before they agree to it.
  Future<CloudSnapshot?> preview() async {
    final uid = _uidReader();
    if (uid == null) return null;

    return _transport.downloadAll(uid);
  }
}
