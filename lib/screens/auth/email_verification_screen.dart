import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState
    extends State<EmailVerificationScreen> {
  bool isVerified = false;
  bool canResend = false;
  bool loading = false;

  Timer? timer;

  User? get user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();

    isVerified = user?.emailVerified ?? false;

    if (!isVerified) {
      sendVerificationEmail();

      timer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => checkVerification(),
      );
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> checkVerification() async {
    await user?.reload();

    final refreshedUser =
        FirebaseAuth.instance.currentUser;

    if (!mounted) return;

    setState(() {
      isVerified =
          refreshedUser?.emailVerified ?? false;
    });

    if (isVerified) {
      timer?.cancel();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.green,
          content: Text(
            "Email verified successfully!",
          ),
        ),
      );

      Navigator.of(context).popUntil(
        (route) => route.isFirst,
      );
    }
  }

  Future<void> sendVerificationEmail() async {
    try {
      await user?.sendEmailVerification();

      if (!mounted) return;

      setState(() {
        canResend = false;
      });

      await Future.delayed(
        const Duration(seconds: 30),
      );

      if (!mounted) return;

      setState(() {
        canResend = true;
      });
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString(),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isVerified) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xffF5F7FA),

      appBar: AppBar(
        title: const Text("Verify Email"),
        centerTitle: true,
      ),

      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),

          child: Column(
            children: [

              const SizedBox(height: 40),

              const Icon(
                Icons.mark_email_read_rounded,
                size: 110,
                color: Colors.green,
              ),

              const SizedBox(height: 25),

              const Text(
                "Verify Your Email",
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 15),

              Text(
                user?.email ?? "",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  color: Colors.black87,
                ),
              ),

              const SizedBox(height: 25),

              const Text(
                "We've sent a verification email to the address above.\n\nYou can verify now or continue to the dashboard and verify later from your profile.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                ),
              ),

              const SizedBox(height: 35),
                            SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.email),
                  onPressed: canResend
                      ? sendVerificationEmail
                      : null,
                  label: Text(
                    canResend
                        ? "Resend Verification Email"
                        : "Resend Available in 30 Seconds",
                  ),
                ),
              ),

              const SizedBox(height: 15),

              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.refresh),
                  onPressed: loading
                      ? null
                      : () async {
                          setState(() {
                            loading = true;
                          });

                          await checkVerification();

                          if (mounted) {
                            setState(() {
                              loading = false;
                            });
                          }
                        },
                  label: loading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          "I've Verified My Email",
                        ),
                ),
              ),

              const SizedBox(height: 15),

              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(
                    double.infinity,
                    55,
                  ),
                ),
                icon: const Icon(Icons.dashboard),
                label: const Text(
                  "I'll Verify Later",
                ),
                onPressed: () {
                  timer?.cancel();

                  Navigator.of(context).popUntil(
                    (route) => route.isFirst,
                  );
                },
              ),

              const SizedBox(height: 15),

              const Text(
                "You can verify your email anytime from\nProfile → Email Verification.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}