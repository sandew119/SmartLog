import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/google_auth_service.dart';
import '../../services/local_storage_service.dart';
import 'password_forgot_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();

  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool loading = false;
  bool googleLoading = false;
  bool rememberMe = true;
  bool hidePassword = true;

  @override
  void initState() {
    super.initState();
    loadRememberMe();
  }

  Future<void> loadRememberMe() async {
    rememberMe = await LocalStorageService.getRememberMe();

    final savedEmail =
        await LocalStorageService.getUserEmail();

    emailController.text = savedEmail;

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => loading = true);

    try {
      await AuthService.instance.login(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      await LocalStorageService.setRememberMe(
        rememberMe,
      );

      if (rememberMe) {
        await LocalStorageService.saveUserEmail(
          emailController.text.trim(),
        );
      } else {
        await LocalStorageService.saveUserEmail("");
      }

      if (!mounted) return;

      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }

    if (mounted) {
      setState(() => loading = false);
    }
  }

 Future<void> googleLogin() async {
  setState(() => googleLoading = true);

  try {
    await GoogleAuthService.instance.signIn();

    await LocalStorageService.setRememberMe(true);

    if (!mounted) return;

    Navigator.pop(context);
  } catch (e) {
    if (!mounted) return;

    String message = e.toString();

    if (message.contains("network") ||
        message.contains("Network") ||
        message.contains("Socket") ||
        message.contains("Unable to resolve host")) {
      message =
          "No internet connection. Please check your network and try again.";
    } else if (message.contains("cancel")) {
      message = "Google Sign-In was cancelled.";
    } else if (message.contains("10:")) {
      message =
          "Google Sign-In configuration error. Please contact support.";
    } else {
      message = "Google Sign-In failed.\n$message";
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  if (mounted) {
    setState(() => googleLoading = false);
  }
}

  InputDecoration input(
    String label,
    IconData icon,
  ) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xffF5F7FA),

      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),

            child: Form(
              key: _formKey,

              child: Column(
                children: [

                  const Icon(
                    Icons.forest,
                    size: 90,
                    color: Colors.green,
                  ),

                  const SizedBox(height: 20),

                  const Text(
                    "Welcome Back",
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 10),

                  const Text(
                    "Sign in to sync your SmartLog data",
                    style: TextStyle(
                      color: Colors.grey,
                    ),
                  ),

                  const SizedBox(height: 35),

                  TextFormField(
                    controller: emailController,
                    keyboardType:
                        TextInputType.emailAddress,
                    decoration: input(
                      "Email",
                      Icons.email_outlined,
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) {
                        return "Enter email";
                      }

                      if (!v.contains("@")) {
                        return "Invalid email";
                      }

                      return null;
                    },
                  ),

                  const SizedBox(height: 18),

                  TextFormField(
                    controller: passwordController,
                    obscureText: hidePassword,
                    decoration: input(
                      "Password",
                      Icons.lock_outline,
                    ).copyWith(
                      suffixIcon: IconButton(
                        icon: Icon(
                          hidePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () {
                          setState(() {
                            hidePassword =
                                !hidePassword;
                          });
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  Row(
                    children: [

                      Checkbox(
                        value: rememberMe,
                        onChanged: (v) {
                          setState(() {
                            rememberMe = v!;
                          });
                        },
                      ),

                      const Text("Remember Me"),

                      const Spacer(),

                      TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const PasswordForgotScreen(),
                            ),
                          );
                        },
                        child: const Text(
                          "Forgot Password?",
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton(
                      onPressed:
                          loading ? null : login,
                      child: loading
                          ? const CircularProgressIndicator()
                          : const Text("Login"),
                    ),
                  ),

                  const SizedBox(height: 15),

                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: OutlinedButton.icon(
                      onPressed: googleLoading
                          ? null
                          : googleLogin,
                      icon: const Icon(
                        Icons.g_mobiledata,
                        size: 34,
                      ),
                      label: googleLoading
                          ? const CircularProgressIndicator()
                          : const Text(
                              "Continue with Google",
                            ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.center,
                    children: [

                      const Text(
                        "Don't have an account?",
                      ),

                      TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const RegisterScreen(),
                            ),
                          );
                        },
                        child: const Text(
                          "Create Account",
                        ),
                      ),

                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}