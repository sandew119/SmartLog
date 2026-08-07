import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/google_auth_service.dart';
import '../../widgets/measurement_settings_card.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  User? get user => FirebaseAuth.instance.currentUser;

  Future<void> _refreshUser() async {
    await user?.reload();

    if (!mounted) return;

    setState(() {});
  }

  Future<void> _logout() async {
    await GoogleAuthService.instance.signOut();

    if (!mounted) return;

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = user;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Profile"),
        centerTitle: true,
      ),
      // Scrollable rather than a fixed Column with a Spacer: the settings
      // card below pushes the content past a small screen's height, and a
      // Spacer in an overflowing Column throws a layout error.
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 20),

            CircleAvatar(
              radius: 55,
              backgroundColor: Colors.green.shade100,
              backgroundImage: currentUser?.photoURL != null
                  ? NetworkImage(currentUser!.photoURL!)
                  : null,
              child: currentUser?.photoURL == null
                  ? const Icon(
                      Icons.person,
                      size: 60,
                    )
                  : null,
            ),

            const SizedBox(height: 20),

            Text(
              currentUser?.displayName ?? "Guest",
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            Text(
              currentUser?.email ?? "",
              style: const TextStyle(
                color: Colors.grey,
              ),
            ),

            const SizedBox(height: 30),

            Card(
              child: ListTile(
                leading: const Icon(Icons.verified_user),
                title: const Text("Email Verification"),
                subtitle: Text(
                  currentUser?.emailVerified == true
                      ? "Verified"
                      : "Not Verified",
                ),
                trailing: Icon(
                  currentUser?.emailVerified == true
                      ? Icons.check_circle
                      : Icons.cancel,
                  color: currentUser?.emailVerified == true
                      ? Colors.green
                      : Colors.red,
                ),
              ),
            ),

            if (currentUser != null &&
                !currentUser.emailVerified) ...[
              const SizedBox(height: 15),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    // Captured before the await: after it, this closure's
                    // context may belong to a widget that is gone, and the
                    // State's own `mounted` flag does not vouch for it.
                    final messenger = ScaffoldMessenger.of(context);

                    await currentUser.sendEmailVerification();

                    if (!mounted) return;

                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text(
                          "Verification email sent.",
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.email),
                  label: const Text("Send Verification Email"),
                ),
              ),

              const SizedBox(height: 10),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _refreshUser,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Refresh Verification"),
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Available to guests too -- measurement settings are stored
            // locally first and only mirrored to the cloud when signed in.
            const MeasurementSettingsCard(),

            const SizedBox(height: 30),

            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: _logout,
                icon: const Icon(Icons.logout),
                label: const Text(
                  "Logout",
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}