import 'package:flutter/material.dart';

import '../../services/auth_service.dart';

class PasswordForgotScreen extends StatefulWidget {
  const PasswordForgotScreen({super.key});

  @override
  State<PasswordForgotScreen> createState() =>
      _PasswordForgotScreenState();
}

class _PasswordForgotScreenState
    extends State<PasswordForgotScreen> {

  final _formKey = GlobalKey<FormState>();

  final _emailController = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> resetPassword() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _loading = true;
    });

    try {

      await AuthService.instance.resetPassword(
        _emailController.text.trim(),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.green,
          content: Text(
            "Password reset email sent successfully.",
          ),
        ),
      );

      Navigator.pop(context);

    } catch (e) {

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red,
          content: Text(e.toString()),
        ),
      );

    }

    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(

      appBar: AppBar(
        title: const Text(
          "Forgot Password",
        ),
      ),

      body: SafeArea(

        child: SingleChildScrollView(

          padding: const EdgeInsets.all(24),

          child: Form(

            key: _formKey,

            child: Column(

              crossAxisAlignment:
                  CrossAxisAlignment.stretch,

              children: [

                const SizedBox(height: 30),

                const Icon(
                  Icons.lock_reset,
                  size: 90,
                  color: Colors.green,
                ),

                const SizedBox(height: 20),

                const Text(
                  "Reset Password",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 10),

                const Text(
                  "Enter your registered email address.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.grey,
                  ),
                ),

                const SizedBox(height: 40),

                TextFormField(

                  controller: _emailController,

                  keyboardType:
                      TextInputType.emailAddress,

                  decoration: InputDecoration(

                    labelText: "Email",

                    prefixIcon:
                        const Icon(Icons.email),

                    border: OutlineInputBorder(

                      borderRadius:
                          BorderRadius.circular(15),

                    ),

                  ),

                  validator: (value) {

                    if (value == null ||
                        value.trim().isEmpty) {
                      return "Enter your email";
                    }

                    if (!value.contains("@")) {
                      return "Invalid email";
                    }

                    return null;
                  },

                ),

                const SizedBox(height: 30),

                SizedBox(

                  height: 55,

                  child: ElevatedButton(

                    onPressed:
                        _loading
                            ? null
                            : resetPassword,

                    style: ElevatedButton.styleFrom(

                      backgroundColor: Colors.green,

                      foregroundColor: Colors.white,

                    ),

                    child:
                        _loading

                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )

                            : const Text(

                                "Send Reset Link",

                                style: TextStyle(
                                  fontSize: 18,
                                ),

                              ),

                  ),

                ),

              ],

            ),

          ),

        ),

      ),

    );

  }

}