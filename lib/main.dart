import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/auth/auth_gate.dart';
import 'services/google_auth_service.dart';
import 'services/cloud_sync_coordinator.dart';
import 'services/cloud_sync_engine.dart';
import 'services/session_timeout_service.dart';
import 'services/user_preferences_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Load measurement settings before the first frame so no screen ever
  // renders a volume using the wrong method, and route settings changes into
  // the sync queue. A settings failure must never block app start.
  try {
    await UserPreferencesService.instance.load();
    UserPreferencesService.instance.syncCallback =
        (_) => CloudSyncEngine.instance.queueSettings();
  } catch (_) {}

  // Anything left in the queue from a previous run goes now: the app may
  // have been killed mid-upload, or closed in a yard with no signal.
  unawaited(CloudSyncEngine.instance.drain());

  // Watches for sign-in, so a fresh install restores its data and everything
  // already on this phone gets swept up to the cloud once.
  CloudSyncCoordinator.instance.start();

  // Signs out a session left open on a phone put down in a yard. Wired here
  // rather than in the auth screens so there is exactly one place that
  // decides what "idle" means.
  SessionTimeoutService.instance.onTimeout = () async {
    SessionTimeoutService.instance.stop();
    await GoogleAuthService.instance.signOut();
  };

  runApp(const SessionActivityDetector(child: SmartLogApp()));
}

class SmartLogApp extends StatelessWidget {
  /// Overridable so the app shell can be tested without Firebase.
  ///
  /// [AuthGate] touches `FirebaseAuth.instance` as it builds, which throws
  /// when Firebase has not been initialised -- as it has not in a widget
  /// test. Injecting the first screen means the theme, title and shell are
  /// actually covered instead of startup going untested altogether.
  final Widget? home;

  const SmartLogApp({super.key, this.home});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Log',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
      ),
      home: home ?? const AuthGate(),
    );
  }
}
