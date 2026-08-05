import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'user_preferences_service.dart';

/// Best-effort, one-way mirror of the user's measurement settings into their
/// Firestore profile document, following the same rules as
/// [CloudStackSyncService]: a no-op when signed out, and every Firestore
/// call swallows its own errors so an offline device never fails a local
/// settings change.
///
/// Settings are not read back down from the cloud in this version -- they
/// are local-first, same deliberate scope cut as stack syncing.
class CloudPreferencesSyncService {
  CloudPreferencesSyncService._();

  static final instance = CloudPreferencesSyncService._();

  // A getter, not an eager field: `FirebaseFirestore.instance` throws when
  // Firebase isn't initialized, which would blow up at construction time
  // before any of the try/catch guards below could apply.
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  String? get _uid {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  Future<void> push(UserPreferences prefs) async {
    try {
      final uid = _uid;
      if (uid == null) return;

      // merge:true is essential here -- unlike the stack collections, this
      // service does NOT own users/{uid}. A plain set() would wipe the
      // name/email/phone/company/photoUrl fields written at registration.
      await _firestore.collection("users").doc(uid).set(
            prefs.toMap(),
            SetOptions(merge: true),
          );
    } catch (_) {}
  }
}
