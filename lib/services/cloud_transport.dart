import 'package:cloud_firestore/cloud_firestore.dart';

/// Everything one user has in the cloud, as plain maps.
class CloudSnapshot {
  /// Each entry is the stored document plus a "cloudId" key holding the
  /// document's own id, so a restore can record where each row came from.
  final List<Map<String, Object?>> stacks;

  /// Keyed by the cloud id of the stack the logs belong to.
  final Map<String, List<Map<String, Object?>>> logsByStack;

  final List<Map<String, Object?>> standaloneLogs;

  final Map<String, Object?>? settings;

  const CloudSnapshot({
    this.stacks = const [],
    this.logsByStack = const {},
    this.standaloneLogs = const [],
    this.settings,
  });

  bool get isEmpty =>
      stacks.isEmpty && standaloneLogs.isEmpty && logsByStack.isEmpty;

  int get logCount =>
      standaloneLogs.length +
      logsByStack.values.fold<int>(0, (total, logs) => total + logs.length);
}

/// The cloud, as the sync engine needs to see it.
///
/// An interface rather than a direct dependency on Firestore, because the
/// engine's job -- ordering, retrying, not losing anything, not duplicating
/// anything -- is exactly the part that must be provably correct, and none of
/// it can be tested against a real Firestore on a machine with no device and
/// no network.
abstract class CloudTransport {
  Future<void> upsertStack(
    String uid,
    String cloudId,
    Map<String, Object?> data,
  );

  Future<void> upsertLog(
    String uid,
    String stackCloudId,
    String cloudId,
    Map<String, Object?> data,
  );

  Future<void> upsertStandaloneLog(
    String uid,
    String cloudId,
    Map<String, Object?> data,
  );

  Future<void> upsertSettings(String uid, Map<String, Object?> data);

  Future<void> deleteStack(String uid, String cloudId);

  /// [stackCloudId] is null for a standalone log.
  Future<void> deleteLog(String uid, String? stackCloudId, String cloudId);

  Future<CloudSnapshot> downloadAll(String uid);
}

class FirestoreCloudTransport implements CloudTransport {
  const FirestoreCloudTransport();

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _user(String uid) =>
      _db.collection("users").doc(uid);

  @override
  Future<void> upsertStack(
    String uid,
    String cloudId,
    Map<String, Object?> data,
  ) {
    return _user(uid).collection("stacks").doc(cloudId).set(data);
  }

  @override
  Future<void> upsertLog(
    String uid,
    String stackCloudId,
    String cloudId,
    Map<String, Object?> data,
  ) {
    return _user(uid)
        .collection("stacks")
        .doc(stackCloudId)
        .collection("logs")
        .doc(cloudId)
        .set(data);
  }

  @override
  Future<void> upsertStandaloneLog(
    String uid,
    String cloudId,
    Map<String, Object?> data,
  ) {
    return _user(uid).collection("standaloneLogs").doc(cloudId).set(data);
  }

  @override
  Future<void> upsertSettings(String uid, Map<String, Object?> data) {
    // merge:true is essential: users/{uid} also holds the name, email, phone,
    // company and photo written at registration, and this service does not
    // own any of them. A plain set() would erase the lot.
    return _user(uid).set(data, SetOptions(merge: true));
  }

  @override
  Future<void> deleteStack(String uid, String cloudId) async {
    final stack = _user(uid).collection("stacks").doc(cloudId);

    // Firestore does not delete subcollections with their parent, so the
    // logs would otherwise be left orphaned and still billable.
    final logs = await stack.collection("logs").get();
    for (final log in logs.docs) {
      await log.reference.delete();
    }

    await stack.delete();
  }

  @override
  Future<void> deleteLog(String uid, String? stackCloudId, String cloudId) {
    final ref = stackCloudId == null
        ? _user(uid).collection("standaloneLogs").doc(cloudId)
        : _user(uid)
            .collection("stacks")
            .doc(stackCloudId)
            .collection("logs")
            .doc(cloudId);

    return ref.delete();
  }

  @override
  Future<CloudSnapshot> downloadAll(String uid) async {
    final stacksSnapshot = await _user(uid).collection("stacks").get();

    final stacks = <Map<String, Object?>>[];
    final logsByStack = <String, List<Map<String, Object?>>>{};

    for (final doc in stacksSnapshot.docs) {
      stacks.add({...doc.data(), "cloudId": doc.id});

      final logs = await doc.reference.collection("logs").get();

      logsByStack[doc.id] = [
        for (final log in logs.docs) {...log.data(), "cloudId": log.id},
      ];
    }

    final standalone = await _user(uid).collection("standaloneLogs").get();
    final profile = await _user(uid).get();

    return CloudSnapshot(
      stacks: stacks,
      logsByStack: logsByStack,
      standaloneLogs: [
        for (final doc in standalone.docs) {...doc.data(), "cloudId": doc.id},
      ],
      settings: profile.data(),
    );
  }
}
