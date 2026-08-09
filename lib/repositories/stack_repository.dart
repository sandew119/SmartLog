import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

import '../database/local_db.dart';
import '../models/log_measurement.dart';
import '../models/log_model.dart';
import '../models/saved_item.dart';
import '../models/stack_model.dart';
import '../services/cloud_sync_engine.dart';

/// The only entry point screens/widgets should use to create or modify
/// stacks and logs. Every method writes to the local database first — the
/// real source of truth, always available offline — and queues the change
/// for the cloud. Queuing, rather than pushing, is the difference between a
/// backup that survives a day in a timber yard with no signal and one that
/// quietly loses whatever happened while the bars were empty.
class StackRepository {
  StackRepository._();

  static final instance = StackRepository._();

  CloudSyncEngine get _cloud => CloudSyncEngine.instance;

  Future<int> createStackAndAddLog({
    required String name,
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
    LogMeasurement? measurement,
    double? deductionInches,
  }) async {
    final stackId = await LocalDB.createStack(name, 0);

    await LocalDB.addLogAndUpdateStackVolume(
      stackId: stackId,
      diameter: diameter,
      lengthFeet: lengthFeet,
      volume: volume,
      cost: cost,
      measurementSource: measurement?.source.name,
      rawDiameterInches: measurement?.minDiameterInches,
      deductionInches: deductionInches,
      diameterToleranceInches: measurement?.diameterToleranceInches,
      measurementQuality: measurement?.quality.name,
      diameterProfile: measurement?.encodedProfile,
    );

    unawaited(_syncStack(stackId));

    return stackId;
  }

  Future<int> addLogToStack({
    required int stackId,
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
    LogMeasurement? measurement,
    double? deductionInches,
  }) async {
    final logId = await LocalDB.addLogAndUpdateStackVolume(
      stackId: stackId,
      diameter: diameter,
      lengthFeet: lengthFeet,
      volume: volume,
      cost: cost,
      measurementSource: measurement?.source.name,
      rawDiameterInches: measurement?.minDiameterInches,
      deductionInches: deductionInches,
      diameterToleranceInches: measurement?.diameterToleranceInches,
      measurementQuality: measurement?.quality.name,
      diameterProfile: measurement?.encodedProfile,
    );

    unawaited(_syncStack(stackId));

    return logId;
  }

  /// Creates a stack with no logs yet -- used when the user picks "create a
  /// new stack" before measuring any logs.
  ///
  /// [customerName] and [remarks] are optional; a stack is perfectly valid
  /// without them. There is deliberately no company parameter: the seller's
  /// company belongs to the user's profile, not to each stack.
  Future<int> createEmptyStack(
    String name, {
    String? customerName,
    String? remarks,
  }) async {
    final stackId = await LocalDB.createStack(
      name,
      0,
      customerName: customerName,
      remarks: remarks,
    );

    unawaited(_cloud.queueStack(stackId));

    return stackId;
  }

  Future<int> saveStandaloneLog({
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
    LogMeasurement? measurement,
    double? deductionInches,
  }) async {
    final logId = await LocalDB.addStandaloneLog(
      diameter: diameter,
      lengthFeet: lengthFeet,
      volume: volume,
      cost: cost,
      measurementSource: measurement?.source.name,
      rawDiameterInches: measurement?.minDiameterInches,
      deductionInches: deductionInches,
      diameterToleranceInches: measurement?.diameterToleranceInches,
      measurementQuality: measurement?.quality.name,
      diameterProfile: measurement?.encodedProfile,
    );

    unawaited(_syncStandaloneLog(logId));

    return logId;
  }

  Future<void> deleteStack(int id) async {
    // Read the cloud identity before the row goes: afterwards there is
    // nothing left to look it up from, and a delete that cannot name its
    // document leaves the copy in the cloud behind for ever.
    final stackRow = await LocalDB.getStack(id);
    final logRows = await LocalDB.getLogsForStack(id);

    await LocalDB.deleteStack(id);

    // Removing the stack in the cloud takes its logs subcollection with it,
    // so the logs need no delete entries of their own. What they must not
    // keep is a queued *upsert*: draining that after the stack is gone would
    // recreate the subcollection and leave orphaned logs behind for ever.
    for (final log in logRows) {
      await LocalDB.dropQueuedUpsert(SyncEntity.log, log["id"] as int);
    }

    unawaited(
      _cloud.queueStackDeletion(stackRow?["cloudId"] as String?, localId: id),
    );
  }

  Future<void> deleteLog(int id) async {
    final row = await LocalDB.getLog(id);
    final stackId = row?["stackId"] as int?;
    final cloudId = row?["cloudId"] as String?;

    String? stackCloudId;
    if (stackId != null) {
      final stackRow = await LocalDB.getStack(stackId);
      stackCloudId = stackRow?["cloudId"] as String?;
    }

    await LocalDB.deleteLog(id);

    unawaited(
      _cloud.queueLogDeletion(
        cloudId,
        stackCloudId: stackCloudId,
        localId: id,
      ),
    );

    // The stack's running totals just changed, so its own document is stale.
    if (stackId != null) unawaited(_cloud.queueStack(stackId));
  }

  Future<void> _syncStack(int stackId) async {
    await _cloud.queueStack(stackId);

    final logRows = await LocalDB.getLogsForStack(stackId);
    if (logRows.isEmpty) return;

    // Only the just-added log needs queueing -- ordered "id DESC" so the
    // first row is the most recent insert.
    await _cloud.queueLog(logRows.first["id"] as int, stackId: stackId);
  }

  Future<void> _syncStandaloneLog(int logId) async {
    await _cloud.queueLog(logId);
  }

  /// Saved items narrowed by a keyword and/or a date range.
  ///
  /// The keyword is matched in SQL against a stack's name, customer and
  /// remarks, and in Dart against a standalone log's figures -- a log has no
  /// name to search, so "20" reasonably means a 20-inch log.
  Future<List<SavedItem>> searchSavedItems({
    String? keyword,
    DateTime? from,
    DateTime? to,
  }) async {
    final stackRows = await LocalDB.searchStacks(
      keyword: keyword,
      from: from,
      to: to,
    );

    final stackItems = await Future.wait(
      stackRows.map((row) async {
        final stack = StackModel.fromMap(row);
        final logRows = await LocalDB.getLogsForStack(stack.id);
        return SavedItem.stack(stack, logCount: logRows.length);
      }),
    );

    final term = keyword?.trim().toLowerCase() ?? "";

    final logItems = [
      for (final row in await LocalDB.getStandaloneLogs())
        SavedItem.log(LogModel.fromMap(row)),
    ].where((item) {
      final log = item.log!;

      if (from != null && log.createdAt.isBefore(from)) return false;
      if (to != null && log.createdAt.isAfter(to)) return false;

      if (term.isEmpty) return true;

      return "${log.diameter.toStringAsFixed(1)} "
              "${log.lengthFeet.toStringAsFixed(1)} "
              "${log.volume.toStringAsFixed(2)} single log"
          .contains(term);
    });

    final all = [...stackItems, ...logItems];
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return all;
  }

  /// Every saved stack and standalone log, merged into one
  /// reverse-chronological list -- shared by the Saved Stacks and Reports
  /// screens so the combining logic only lives in one place.
  /// The signed-in account, or null in guest mode.
  ///
  /// Read through a function so this file imports no Firebase and stays
  /// testable; overridable so a test can act as a given user.
  static String? Function() currentUserId = () {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  };

  Future<List<SavedItem>> loadSavedItems() async {
    // "A user can retrieve only the records owned by that user" -- which
    // nothing enforced locally before, so two accounts sharing a phone saw
    // each other's stacks.
    final stackRows = await LocalDB.getStacks(userId: currentUserId());
    final standaloneRows = await LocalDB.getStandaloneLogs();

    final stackItems = await Future.wait(
      stackRows.map((row) async {
        final stack = StackModel.fromMap(row);
        final logRows = await LocalDB.getLogsForStack(stack.id);
        return SavedItem.stack(stack, logCount: logRows.length);
      }),
    );

    final logItems =
        standaloneRows.map((row) => SavedItem.log(LogModel.fromMap(row)));

    final all = [...stackItems, ...logItems];
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return all;
  }
}
