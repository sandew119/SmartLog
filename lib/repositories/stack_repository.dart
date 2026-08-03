import 'dart:async';

import '../database/local_db.dart';
import '../models/log_model.dart';
import '../models/saved_item.dart';
import '../models/stack_model.dart';
import '../services/cloud_stack_sync_service.dart';

/// The only entry point screens/widgets should use to create or modify
/// stacks and logs. Every method writes to the local database first (the
/// real source of truth, always available offline) and then mirrors the
/// change to Firestore in the background when signed in — the cloud push
/// never blocks or fails the local write.
class StackRepository {
  StackRepository._();

  static final instance = StackRepository._();

  final CloudStackSyncService _cloud = CloudStackSyncService.instance;

  Future<int> createStackAndAddLog({
    required String name,
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
  }) async {
    final stackId = await LocalDB.createStack(name, 0);

    await LocalDB.addLogAndUpdateStackVolume(
      stackId: stackId,
      diameter: diameter,
      lengthFeet: lengthFeet,
      volume: volume,
      cost: cost,
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
  }) async {
    final logId = await LocalDB.addLogAndUpdateStackVolume(
      stackId: stackId,
      diameter: diameter,
      lengthFeet: lengthFeet,
      volume: volume,
      cost: cost,
    );

    unawaited(_syncStack(stackId));

    return logId;
  }

  /// Creates a stack with no logs yet -- used when the user picks "create a
  /// new stack" before measuring any logs.
  Future<int> createEmptyStack(String name) async {
    final stackId = await LocalDB.createStack(name, 0);

    final stackRow = await LocalDB.getStack(stackId);
    if (stackRow != null) {
      unawaited(_cloud.pushStack(StackModel.fromMap(stackRow)));
    }

    return stackId;
  }

  Future<int> saveStandaloneLog({
    required double diameter,
    required double lengthFeet,
    required double volume,
    double cost = 0,
  }) async {
    final logId = await LocalDB.addStandaloneLog(
      diameter: diameter,
      lengthFeet: lengthFeet,
      volume: volume,
      cost: cost,
    );

    unawaited(_syncStandaloneLog(logId));

    return logId;
  }

  Future<void> deleteStack(int id) async {
    await LocalDB.deleteStack(id);
    unawaited(_cloud.deleteStack(id));
  }

  Future<void> deleteLog(int id) async {
    final row = await LocalDB.getLog(id);
    final stackId = row?["stackId"] as int?;

    await LocalDB.deleteLog(id);
    unawaited(_cloud.deleteLog(id, stackId: stackId));
  }

  Future<void> _syncStack(int stackId) async {
    final stackRow = await LocalDB.getStack(stackId);
    if (stackRow == null) return;

    await _cloud.pushStack(StackModel.fromMap(stackRow));

    final logRows = await LocalDB.getLogsForStack(stackId);
    if (logRows.isEmpty) return;

    // Only the just-added log needs pushing -- ordered "id DESC" so the
    // first row is the most recent insert.
    await _cloud.pushLog(stackId, LogModel.fromMap(logRows.first));
  }

  Future<void> _syncStandaloneLog(int logId) async {
    final row = await LocalDB.getLog(logId);
    if (row == null) return;

    await _cloud.pushStandaloneLog(LogModel.fromMap(row));
  }

  /// Every saved stack and standalone log, merged into one
  /// reverse-chronological list -- shared by the Saved Stacks and Reports
  /// screens so the combining logic only lives in one place.
  Future<List<SavedItem>> loadSavedItems() async {
    final stackRows = await LocalDB.getStacks();
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
