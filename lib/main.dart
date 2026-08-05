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
  const SmartLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartLog',
      debugShowCheckedModeBanner: false,

      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
      ),

      home: const AuthGate(),
    );
  }
}