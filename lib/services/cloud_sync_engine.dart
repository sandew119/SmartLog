import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../database/local_db.dart';
import 'cloud_sync_status.dart';
import 'cloud_transport.dart';
import 'local_storage_service.dart';
import 'user_preferences_service.dart';

/// Entity names as stored in the outbox. Strings rather than an enum because
/// they are persisted in SQLite and must survive an app upgrade unchanged.
class SyncEntity {
  static const stack = "stack";
  static const log = "log";
  static const standaloneLog = "standaloneLog";
  static const settings = "settings";
}

/// Uploads everything on this phone to the user's cloud account, and keeps
/// doing it until it has actually arrived.
///
/// The rule the whole design follows: **the phone is the source of truth and
/// the cloud is a mirror of it.** A push that cannot go through is not an
/// error the user has to deal with -- it is work still queued. That is why
/// mutations write to the local database and an outbox row in one breath,
/// and nothing is ever dropped just because the signal was bad.
class CloudSyncEngine {
  CloudSyncEngine({CloudTransport? transport, String? Function()? uid})
      : _transport = transport ?? const FirestoreCloudTransport(),
        _uidReader = uid ?? _firebaseUid;

  static final CloudSyncEngine instance = CloudSyncEngine();

  final CloudTransport _transport;
  final String? Function() _uidReader;

  /// Reading `FirebaseAuth.instance` can itself throw when Firebase has not
  /// been initialised, which is a no-op here rather than a crash.
  static String? _firebaseUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  /// The drain currently running, if any.
  ///
  /// Held so that a second caller gets *that* future back rather than a
  /// completed one. Returning early would make `await drain()` a lie -- it
  /// would resolve while the upload was still in flight, which is exactly
  /// the sort of thing that makes a sync layer look like it works until the
  /// day it matters.
  Future<void>? _inFlight;

  /// Set while a drain is running and more work arrives, so the run in
  /// progress goes round again instead of the new work waiting for the next
  /// trigger.
  bool _drainAgain = false;

  Timer? _retryTimer;

  /// How long to wait before retrying after a failure. Long enough not to
  /// burn a phone battery retrying a broken configuration all afternoon,
  /// short enough that a lorry driving back into signal syncs by itself.
  static const Duration retryInterval = Duration(minutes: 2);

  /// Pending work, so the UI can say "3 logs waiting to back up".
  final ValueNotifier<int> pending = ValueNotifier(0);

  // --- queueing -------------------------------------------------------------

  Future<void> queueStack(int stackId) async {
    await LocalDB.enqueueUpsert(entity: SyncEntity.stack, localId: stackId);
    unawaited(drain());
  }

  Future<void> queueLog(int logId, {int? stackId}) async {
    await LocalDB.enqueueUpsert(
      entity: stackId == null ? SyncEntity.standaloneLog : SyncEntity.log,
      localId: logId,
      parentLocalId: stackId,
    );
    unawaited(drain());
  }

  Future<void> queueSettings() async {
    await LocalDB.enqueueSettings();
    unawaited(drain());
  }

  /// [cloudId] null means the row never reached the cloud, so there is
  /// nothing there to delete.
  Future<void> queueStackDeletion(String? cloudId, {int? localId}) async {
    if (cloudId == null) return;

    await LocalDB.enqueueDelete(
      entity: SyncEntity.stack,
      cloudId: cloudId,
      localId: localId,
    );
    unawaited(drain());
  }

  Future<void> queueLogDeletion(
    String? cloudId, {
    String? stackCloudId,
    int? localId,
  }) async {
    if (cloudId == null) return;

    await LocalDB.enqueueDelete(
      entity: stackCloudId == null ? SyncEntity.standaloneLog : SyncEntity.log,
      cloudId: cloudId,
      parentCloudId: stackCloudId,
      localId: localId,
    );
    unawaited(drain());
  }

  /// Queues every stack, every log and the settings for upload.
  ///
  /// This is what rescues data written while syncing was broken. Because the
  /// security rules only ever granted access to `users/{uid}` -- and
  /// Firestore rules do not reach into subcollections -- every stack and log
  /// this app has ever saved was refused. None of it was queued at the time,
  /// so without a deliberate sweep like this it would stay on the phone for
  /// ever.
  Future<int> queueEverything() async {
    final stacks = await LocalDB.getStacks();

    for (final stack in stacks) {
      await LocalDB.enqueueUpsert(
        entity: SyncEntity.stack,
        localId: stack["id"] as int,
      );
    }

    final logs = await LocalDB.getAllLogs();

    for (final log in logs) {
      final stackId = log["stackId"] as int?;

      await LocalDB.enqueueUpsert(
        entity: stackId == null ? SyncEntity.standaloneLog : SyncEntity.log,
        localId: log["id"] as int,
        parentLocalId: stackId,
      );
    }

    await LocalDB.enqueueSettings();

    final total = await _refreshPending();
    unawaited(drain());

    return total;
  }

  // --- draining -------------------------------------------------------------

  /// Sends whatever is queued, oldest first, and stops at the first failure.
  ///
  /// Stopping rather than skipping ahead is deliberate: the queue is ordered,
  /// and a log cannot be written under a stack that has not been created yet.
  /// Pushing on past a failure would scatter orphans through the cloud.
  Future<void> drain() {
    final running = _inFlight;

    if (running != null) {
      // Work arrived mid-flight: go round again rather than making it wait
      // for the next trigger, and hand this caller the same finish line.
      _drainAgain = true;
      return running;
    }

    final future = _runDrain();
    _inFlight = future;

    return future;
  }

  Future<void> _runDrain() async {
    try {
      do {
        _drainAgain = false;
        await _drainOnce();
      } while (_drainAgain);
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _drainOnce() async {
    final uid = _uidReader();

    if (uid == null) {
      // Guest mode is a supported way to use this app, not a failure.
      CloudSyncStatus.instance.recordSignedOut();
      await _refreshPending();
      return;
    }

    final items = await LocalDB.pendingSyncItems();

    if (items.isEmpty) {
      await _refreshPending();
      return;
    }

    for (final item in items) {
      try {
        await _send(uid, item);
        await LocalDB.removeSyncItem(item["id"] as int);
      } catch (error) {
        await LocalDB.recordSyncAttempt(item["id"] as int, "$error");
        CloudSyncStatus.instance.recordFailure(
          error,
          operation: "backing up a ${item["entity"]}",
        );

        // Leave the rest queued and come back to it.
        _scheduleRetry();
        await _refreshPending();
        return;
      }
    }

    CloudSyncStatus.instance.recordSuccess();
    _retryTimer?.cancel();
    await _refreshPending();
  }

  Future<void> _send(String uid, Map<String, dynamic> item) async {
    final entity = item["entity"] as String;
    final operation = item["operation"] as String;

    if (operation == "delete") {
      final cloudId = item["cloudId"] as String;

      if (entity == SyncEntity.stack) {
        await _transport.deleteStack(uid, cloudId);
      } else {
        await _transport.deleteLog(
          uid,
          item["parentCloudId"] as String?,
          cloudId,
        );
      }

      return;
    }

    if (entity == SyncEntity.settings) {
      await _transport.upsertSettings(
        uid,
        UserPreferencesService.instance.current.toMap(),
      );
      return;
    }

    final localId = item["localId"] as int;

    if (entity == SyncEntity.stack) {
      final row = await LocalDB.getStack(localId);

      // Created and deleted before this ever ran. The delete is queued
      // separately, so there is nothing to do here.
      if (row == null) return;

      final cloudId = await _cloudIdFor("stacks", localId, row["cloudId"]);

      await _transport.upsertStack(uid, cloudId, _document(row));

      return;
    }

    final row = await LocalDB.getLog(localId);
    if (row == null) return;

    final cloudId = await _cloudIdFor("logs", localId, row["cloudId"]);
    final data = _document(row);

    final stackId = row["stackId"] as int?;

    if (stackId == null) {
      await _transport.upsertStandaloneLog(uid, cloudId, data);
      return;
    }

    final stackRow = await LocalDB.getStack(stackId);
    if (stackRow == null) return;

    final stackCloudId =
        await _cloudIdFor("stacks", stackId, stackRow["cloudId"]);

    await _transport.upsertLog(uid, stackCloudId, cloudId, data);
  }

  /// The database row as it should be stored in the cloud.
  ///
  /// Deliberately the whole row and not `Model.toMap()`. `LogModel.toMap()`
  /// carries only the six figures the UI displays and drops every
  /// measurement-provenance column -- where the diameter came from, what
  /// deduction was applied, how good the reading was. Those exist so a
  /// disputed volume can be audited months later, and a backup that quietly
  /// discards them is not a backup of the thing that matters.
  ///
  /// The local row id is kept under a different name: in the cloud the
  /// document id is the identity, and two phones both have a row 7.
  static Map<String, Object?> _document(Map<String, dynamic> row) {
    final data = <String, Object?>{...row};

    data["localId"] = data.remove("id");

    // The document already knows its own id; storing it inside as well would
    // be one more thing that can disagree with itself.
    data.remove("cloudId");

    return data;
  }

  /// The document id a row owns, minted once and then kept.
  ///
  /// Minting includes the device id so two phones adding a log offline cannot
  /// land on the same document, and persisting it is what makes a restore
  /// safe: the restored row keeps the id it came down with, so re-uploading
  /// updates that document instead of creating a duplicate.
  Future<String> _cloudIdFor(
    String table,
    int localId,
    Object? existing,
  ) async {
    final current = existing as String?;
    if (current != null && current.isNotEmpty) return current;

    final deviceId = await LocalStorageService.getOrCreateDeviceId();
    final minted = "${deviceId}_$localId";

    await LocalDB.setCloudId(table, localId, minted);

    return minted;
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(retryInterval, () => unawaited(drain()));
  }

  Future<int> _refreshPending() async {
    final count = await LocalDB.pendingSyncCount();
    pending.value = count;
    return count;
  }

  /// Test seam: timers outlive a test otherwise, and the pending count is
  /// shared state.
  @visibleForTesting
  void disposeForTesting() {
    _retryTimer?.cancel();
    _retryTimer = null;
    pending.value = 0;
  }
}
