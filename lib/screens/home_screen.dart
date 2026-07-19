import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'auth/login_screen.dart';
import 'profile/profile_screen.dart';

import 'manual_calculator_screen.dart';
import 'manual_stack_screen.dart';
import 'saved_stacks_screen.dart';
import 'scan_log_screen.dart';
import 'optimal_cutting_screen.dart';
import 'defect_detection_screen.dart';
import 'reports_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        final user = snapshot.data;

        return Scaffold(
          backgroundColor: const Color(0xffF5F7FA),

          appBar: AppBar(
            centerTitle: true,
            title: const Text(
              "SmartLog",
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
            actions: [
              if (user == null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LoginScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.login),
                    label: const Text("Login"),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: IconButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ProfileScreen(),
                        ),
                      );
                    },
                    icon: CircleAvatar(
                      backgroundColor: Colors.green,
                      backgroundImage: user.photoURL != null
                          ? NetworkImage(user.photoURL!)
                          : null,
                      child: user.photoURL == null
                          ? const Icon(
                              Icons.person,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),

          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Card(
                  child: ListTile(
                    leading: Icon(
                      user == null
                          ? Icons.cloud_off
                          : Icons.cloud_done,
                      color: user == null
                          ? Colors.orange
                          : Colors.green,
                    ),
                    title: Text(
                      user == null
                          ? "Guest Mode"
                          : "Cloud Sync Enabled",
                    ),
                    subtitle: Text(
                      user == null
                          ? "Login to sync your SmartLog data."
                          : (user.email ?? ""),
                    ),
                  ),
                ),

                const SizedBox(height: 15),

                Expanded(
                  child: GridView.count(
                    crossAxisCount: 2,
                    crossAxisSpacing: 15,
                    mainAxisSpacing: 15,
                    children: [
                      _card(
                        context,
                        "Scan Log",
                        Icons.camera_alt,
                        const ScanLogScreen(),
                      ),
                      _card(
                        context,
                        "Manual Calculator",
                        Icons.calculate,
                        const ManualCalculatorScreen(),
                      ),
                      _card(
                        context,
                        "Manual Stack",
                        Icons.layers,
                        const ManualStackScreen(),
                      ),
                      _card(
                        context,
                        "Saved Stacks",
                        Icons.folder,
                        const SavedStacksScreen(),
                      ),
                      _card(
                        context,
                        "Optimal Cutting",
                        Icons.content_cut,
                        const OptimalCuttingScreen(),
                      ),
                      _card(
                        context,
                        "Defect Detection",
                        Icons.warning_amber,
                        const DefectDetectionScreen(),
                      ),
                      _card(
                        context,
                        "Reports",
                        Icons.bar_chart,
                        const ReportsScreen(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _card(
    BuildContext context,
    String title,
    IconData icon,
    Widget screen,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => screen,
          ),
        );
      },
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 50,
              color: Colors.green,
            ),
            const SizedBox(height: 15),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}