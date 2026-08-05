import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class GoogleAuthService {
  GoogleAuthService._();

  static final GoogleAuthService instance = GoogleAuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  bool _initialized = false;

  Future<void> _initialize() async {
    if (_initialized) return;

    // `serverClientId` is the web client, used to obtain the idToken that
    // Firebase verifies. On iOS the plugin ALSO needs the iOS OAuth client
    // id, which it reads from `ios/Runner/GoogleService-Info.plist`. If
    // that file is missing this call throws -- see ios/README-IOS-SETUP.md.
    await _googleSignIn.initialize(
      serverClientId:
          "426376339171-lhv4607m6i72k21vv9bisdklvumkfmrg.apps.googleusercontent.com",
    );

    _initialized = true;
  }

  Future<UserCredential> signIn() async {
    try {
      await _initialize();
    } catch (e) {
      // Turn an opaque platform error into something the user (and whoever
      // is setting the project up) can actually act on.
      throw Exception(
        "Google Sign-In isn't configured for this platform yet. "
        "Add GoogleService-Info.plist to ios/Runner and register its "
        "REVERSED_CLIENT_ID as a URL scheme -- see ios/README-IOS-SETUP.md. "
        "You can still sign in with email and password. ($e)",
      );
    }

    final GoogleSignInAccount googleUser =
        await _googleSignIn.authenticate();

    final GoogleSignInAuthentication googleAuth =
        googleUser.authentication;

    final credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
    );

    final userCredential =
        await _auth.signInWithCredential(credential);

    final user = userCredential.user!;

    final doc =
        _firestore.collection("users").doc(user.uid);

    if (!(await doc.get()).exists) {
      await doc.set({
        "uid": user.uid,
        "name": user.displayName ?? "",
        "email": user.email ?? "",
        "phone": "",
        "company": "",
        "photoUrl": user.photoURL ?? "",
        "provider": "google",
        "emailVerified": user.emailVerified,
        "createdAt": FieldValue.serverTimestamp(),
      });
    }

    return userCredential;
  }

  Future<void> signOut() async {
    // Signing out of Google is best-effort: this runs for every user, but
    // an email/password user never initialised the Google plugin, and on a
    // platform where it isn't configured this call throws. Letting that
    // escape would leave the user unable to log out at all.
    try {
      await _googleSignIn.signOut();
    } catch (_) {}

    await _auth.signOut();
  }
}