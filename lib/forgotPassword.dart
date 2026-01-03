import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'login.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({Key? key}) : super(key: key);

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _emailController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _isLoading = false;
  bool _showNewPassword = false;
  String? _userId;

  // Used in UI for error/success messages
  void _showDialog(String title, String message, {bool error = false, VoidCallback? onOk}) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2D3142),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Icon(
                error ? Icons.error_outline : Icons.lock_reset,
                color: error ? Colors.red : const Color(0xFFE8956C),
                size: 28,
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Text(
            message,
            style: TextStyle(
              color: Colors.white.withOpacity(0.9),
              fontSize: 16,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                if (onOk != null) onOk();
              },
              child: const Text(
                'OK',
                style: TextStyle(
                  color: Color(0xFFE8956C),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _checkEmail() async {
    setState(() { _isLoading = true; });
    String email = _emailController.text.trim();

    if (email.isEmpty) {
      _showDialog('Error', 'Please enter your email address.', error: true);
      setState(() { _isLoading = false; });
      return;
    }

    try {
      // Find user in player_account by email
      QuerySnapshot query = await _firestore
          .collection('player_account')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        _showDialog('Error', 'No account found with this email.', error: true);
        setState(() { _isLoading = false; });
        return;
      }

      DocumentSnapshot userDoc = query.docs.first;
      Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
      _userId = userDoc.id;

      // Check lastPasswordChange
      if (userData.containsKey('lastPasswordChange') && userData['lastPasswordChange'] != null) {
        DateTime lastChange = (userData['lastPasswordChange'] as Timestamp).toDate();
        Duration sinceChange = DateTime.now().difference(lastChange);

        if (sinceChange.inDays < 30) {
          _showDialog(
            'Cooldown Active',
            'You can only change your password once every 30 days.\n\nLast change: ${lastChange.toLocal()}',
            error: true,
            onOk: () {
              // Return to login screen after dialog
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage()));
            },
          );
          setState(() { _isLoading = false; });
          return;
        }
      }

      // Passed all checks, show new password field
      setState(() { _showNewPassword = true; });
    } catch (e) {
      _showDialog('Error', 'An error occurred. Please try again.', error: true);
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _resetPassword() async {
    setState(() { _isLoading = true; });
    String newPassword = _newPasswordController.text.trim();

    if (newPassword.length < 6) {
      _showDialog('Error', 'Password must be at least 6 characters.', error: true);
      setState(() { _isLoading = false; });
      return;
    }

    try {
      // Find user by id
      DocumentReference userRef = _firestore.collection('player_account').doc(_userId);
      DocumentSnapshot userDoc = await userRef.get();
      Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
      String email = userData['email'];

      // Re-authenticate the user for password change (using Firebase Auth REST API or admin privilege)
      // For client-side, you cannot change password directly unless user logs in.
      // Here, you can send a password reset email as workaround, or instruct admin to reset.
      // If you want to force change, you need to implement with Firebase Admin SDK (server-side).
      // For this example, just send the password reset email:
      await _auth.sendPasswordResetEmail(email: email);

      // Update lastPasswordChange in Firestore
      await userRef.update({
        'lastPasswordChange': Timestamp.now(),
      });

      _showDialog(
        'Password Reset Email Sent',
        'A password reset email has been sent to $email. Please check your inbox.',
        onOk: () {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage(showSecurityMessage: true)));
        },
      );
    } catch (e) {
      _showDialog('Error', 'Failed to reset password. Please try again.', error: true);
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF2D3142),
              Color(0xFF1A1D2E),
            ],
          ),
        ),
        child: SafeArea(
          child: GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 30),
              children: [
                const SizedBox(height: 60),
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFFE8956C),
                        Color(0xFFD4794A),
                      ],
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: Image.asset(
                      'assets/ictrllogo.png',
                      fit: BoxFit.cover,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                Text(
                  "Forgot Password",
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  _showNewPassword
                      ? "Enter your new password"
                      : "Enter your email to reset your password",
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white.withOpacity(0.7),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),

                if (!_showNewPassword) ...[
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Email',
                      labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                      prefixIcon: Icon(
                        Icons.email_outlined,
                        color: Colors.white.withOpacity(0.7),
                      ),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.1),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: const BorderSide(
                          color: Color(0xFFE8956C),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _checkEmail,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE8956C),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                        elevation: 5,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                          : const Text(
                        'Next',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
                if (_showNewPassword) ...[
                  TextFormField(
                    controller: _newPasswordController,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'New Password',
                      labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                      prefixIcon: Icon(
                        Icons.lock_outline,
                        color: Colors.white.withOpacity(0.7),
                      ),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.1),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: const BorderSide(
                          color: Color(0xFFE8956C),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _resetPassword,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE8956C),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                        elevation: 5,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                          : const Text(
                        'Reset Password',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () {
                    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage()));
                  },
                  child: const Text(
                    'Back to Login',
                    style: TextStyle(
                      color: Color(0xFFE8956C),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
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