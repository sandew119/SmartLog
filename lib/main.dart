import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/auth/auth_gate.dart';
import 'services/cloud_preferences_sync_service.dart';
import 'services/user_preferences_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Load measurement settings before the first frame so no screen ever
  // renders a volume using the wrong method, and install the best-effort
  // cloud mirror. A settings failure must never block app start.
  try {
    await UserPreferencesService.instance.load();
    UserPreferencesService.instance.syncCallback =
        CloudPreferencesSyncService.instance.push;
  } catch (_) {}

  runApp(const SmartLogApp());
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