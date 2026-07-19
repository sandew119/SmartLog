import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential> login({
    required String email,
    required String password,
  }) async {
    try {
      return await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
    } on FirebaseAuthException catch (e) {
      throw _message(e.code);
    }
  }

  Future<UserCredential> register({
    required String name,
    required String email,
    required String password,
    String phone = "",
    String company = "",
  }) async {
    try {
      final credential =
          await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      await credential.user!.updateDisplayName(name);

      await credential.user!.sendEmailVerification();

      await _firestore
          .collection("users")
          .doc(credential.user!.uid)
          .set({
        "uid": credential.user!.uid,
        "name": name,
        "email": email.trim(),
        "phone": phone,
        "company": company,
        "photoUrl": "",
        "provider": "email",
        "emailVerified": false,
        "createdAt": FieldValue.serverTimestamp(),
      });

      return credential;
    } on FirebaseAuthException catch (e) {
      throw _message(e.code);
    }
  }

  Future<void> resetPassword(
    String email,
  ) async {
    try {
      await _auth.sendPasswordResetEmail(
        email: email.trim(),
      );
    } on FirebaseAuthException catch (e) {
      throw _message(e.code);
    }
  }

  Future<void> refreshUser() async {
    await _auth.currentUser?.reload();

    final user = _auth.currentUser;

    if (user != null) {
      await _firestore
          .collection("users")
          .doc(user.uid)
          .update({
        "emailVerified": user.emailVerified,
      });
    }
  }

  Future<void> logout() async {
    await _auth.signOut();
  }

  String _message(String code) {
    switch (code) {
      case "invalid-email":
        return "Invalid email address.";

      case "invalid-credential":
      case "wrong-password":
        return "Incorrect email or password.";

      case "user-not-found":
        return "No account found.";

      case "email-already-in-use":
        return "Email already exists.";

      case "weak-password":
        return "Password is too weak.";

      case "network-request-failed":
        return "No internet connection.";

      case "too-many-requests":
        return "Too many attempts. Try later.";

      default:
        return code;
    }
  }
}