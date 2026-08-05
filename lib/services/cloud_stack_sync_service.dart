import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/log_model.dart';
import '../models/stack_model.dart';
import 'local_storage_service.dart';

/// One-way, best-effort mirror of local stack/log data into Firestore.
///
/// This is a backup, not a source of truth: every method is a no-op when
/// signed out (guest mode), and every Firestore call swallows its own
/// errors so an offline or failed push never affects the local-first flow.
/// Cloud data is never read back down into the app in this version — that's
/// a deliberate scope cut, not a bug.
class CloudStackSyncService {
  CloudStackSyncService._();

  static final instance = CloudStackSyncService._();

  // A getter, not an eagerly-initialized field: `FirebaseFirestore.instance`
  // itself throws if Firebase hasn't been initialized, and every call site
  // here already runs inside a try/catch -- an eager field would throw at
  // construction time instead, before any of those guards apply, crashing
  // the very first stack/log save rather than just skipping the cloud push.
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  /// Reading `FirebaseAuth.instance` itself can throw (e.g. Firebase not
  /// initialized in this context) -- swallow that the same as any other
  /// sync failure so this is always a true no-op rather than a crash.
  String? get _uid {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  Future<void> pushStack(StackModel stack) async {
    try {
      final uid = _uid;
      if (uid == null) return;

      final doc = await _stackDoc(uid, stack.id);
      await doc.set(stack.toMap());
    } catch (_) {}
  }

  Future<void> pushLog(int stackId, LogModel log) async {
    try {
      final uid = _uid;
      if (uid == null) return;

      final deviceId = await LocalStorageService.getOrCreateDeviceId();
      final doc = await _stackDoc(uid, stackId);

      await doc.collection("logs").doc("${deviceId}_${log.id}").set(
            log.toMap(),
          );
    } catch (_) {}
  }

  Future<void> pushStandaloneLog(LogModel log) async {
    try {
      final uid = _uid;
      if (uid == null) return;

      final deviceId = await LocalStorageService.getOrCreateDeviceId();

      await _firestore
          .collection("users")
          .doc(uid)
          .collection("standaloneLogs")
          .doc("${deviceId}_${log.id}")
          .set(log.toMap());
    } catch (_) {}
  }

  Future<void> deleteStack(int stackId) async {
    try {
      final uid = _uid;
      if (uid == null) return;

      final doc = await _stackDoc(uid, stackId);

      final logDocs = await doc.collection("logs").get();

      for (final logDoc in logDocs.docs) {
        await logDoc.reference.delete();
      }

      await doc.delete();
    } catch (_) {}
  }

  Future<void> deleteLog(int logId, {int? stackId}) async {
    try {
      final uid = _uid;
      if (uid == null) return;

      final deviceId = await LocalStorageService.getOrCreateDeviceId();

      final docRef = stackId != null
          ? (await _stackDoc(uid, stackId)).collection("logs").doc(
                "${deviceId}_$logId",
              )
          : _firestore
              .collection("users")
              .doc(uid)
              .collection("standaloneLogs")
              .doc("${deviceId}_$logId");

      await docRef.delete();
    } catch (_) {}
  }

  Future<DocumentReference<Map<String, dynamic>>> _stackDoc(
    String uid,
    int stackId,
  ) async {
    final deviceId = await LocalStorageService.getOrCreateDeviceId();

    return _firestore
        .collection("users")
        .doc(uid)
        .collection("stacks")
        .doc("${deviceId}_$stackId");
  }
}
