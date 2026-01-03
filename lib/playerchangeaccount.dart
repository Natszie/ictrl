import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'dart:math';
import 'dart:async';
import 'login.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class PlayerChangeAccountScreen extends StatefulWidget {
  final String username;
  final String email;

  const PlayerChangeAccountScreen({
    Key? key,
    required this.username,
    required this.email,
  }) : super(key: key);

  @override
  State<PlayerChangeAccountScreen> createState() => _PlayerChangeAccountScreenState();
}

class _PlayerChangeAccountScreenState extends State<PlayerChangeAccountScreen> {
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _oldPasswordController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();

  bool _isOtpSent = false;
  bool _isLoading = false;
  String? _sentOtp;
  String? _error;
  int _remainingTime = 300; // 5 minutes in seconds
  bool _isResendEnabled = false;
  Timer? _timer;
  int _failedAttempts = 0;
  bool _showForgotPassword = false;

  // Colors (matching your theme)
  static const Color accentColor = Color(0xFFE8956C);
  static const Color backgroundTop = Color(0xFF2D3142);
  static const Color backgroundBottom = Color(0xFF1A1D2E);

  @override
  void dispose() {
    _otpController.dispose();
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  // Generate a random 6-digit OTP
  String _generateOTP() {
    final random = Random();
    return List.generate(6, (_) => random.nextInt(10)).join();
  }

  void _startTimer() {
    _timer?.cancel();
    _remainingTime = 300;
    _isResendEnabled = false;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingTime > 0) {
        setState(() {
          _remainingTime--;
        });
      } else {
        setState(() {
          _isResendEnabled = true;
        });
        timer.cancel();
      }
    });
  }

  String _formatTime(int seconds) {
    int minutes = seconds ~/ 60;
    int remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  // Send OTP via email using SMTP (Gmail App password)
  Future<void> _sendOtp() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final smtpServer = gmail('ictrlinc@gmail.com', 'wydj cspi nsdz ljqc');
    final otp = _generateOTP();
    _sentOtp = otp;

    final message = Message()
      ..from = Address('parenteyeinc@gmail.com', 'iCtrl Password Change')
      ..recipients.add(widget.email)
      ..subject = 'Your Password Change OTP'
      ..html = '''
        <div style="font-family: Arial; max-width: 400px; margin: auto;">
          <h2 style="color: #E8956C;">Password Change Request</h2>
          <p>Hello ${widget.username},</p>
          <p>Your OTP for password change is:</p>
          <div style="background: #2D3142; color: #E8956C; font-size: 32px; text-align: center; border-radius: 8px; padding: 16px; font-weight:bold;">$otp</div>
          <p>This code will expire in 5 minutes.</p>
          <p>If you didn't request this, please ignore this email.</p>
        </div>
      ''';

    try {
      await send(message, smtpServer);
      setState(() {
        _isOtpSent = true;
        _isLoading = false;
      });
      _startTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("OTP sent to ${widget.email}"), backgroundColor: Colors.green),
      );
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = "Failed to send OTP: $e";
      });
    }
  }

  // Handle password change logic
  Future<void> _changePassword() async {
    setState(() { _isLoading = true; _error = null; });

    final oldPassword = _oldPasswordController.text.trim();
    final newPassword = _newPasswordController.text.trim();
    final otp = _otpController.text.trim();
    final user = FirebaseAuth.instance.currentUser;

    // Check OTP first
    if (otp != _sentOtp) {
      setState(() {
        _error = "Invalid OTP. Please check your email for the correct code.";
        _isLoading = false;
      });
      return;
    }

    // Check cooldown from Firestore
    final doc = await FirebaseFirestore.instance.collection('player_account').doc(user?.uid).get();
    final lastChange = doc.data()?['lastPasswordChange'] as Timestamp?;
    if (lastChange != null) {
      final daysSinceChange = DateTime.now().difference(lastChange.toDate()).inDays;
      if (daysSinceChange < 30) {
        setState(() {
          _error = "You can only change your password once every 30 days.";
          _isLoading = false;
        });
        return;
      }
    }

    // Re-authenticate user
    try {
      final cred = EmailAuthProvider.credential(
        email: user?.email ?? widget.email,
        password: oldPassword,
      );
      await user?.reauthenticateWithCredential(cred);
    } catch (e) {
      _failedAttempts++;
      setState(() {
        _error = "Re-authentication failed. Please enter your current password correctly.";
        _isLoading = false;
        if (_failedAttempts >= 2) {
          _showForgotPassword = true;
        }
      });
      return;
    }

    // Try to change password in Firebase Auth
    try {
      await user?.updatePassword(newPassword);
      // Update cooldown in Firestore
      await FirebaseFirestore.instance.collection('player_account').doc(user?.uid)
          .update({'lastPasswordChange': Timestamp.now()});
      setState(() { _isLoading = false; });
      _showSuccessDialog();
    } catch (e) {
      setState(() {
        _error = "Failed to change password: ${e.toString()}";
        _isLoading = false;
      });
    }
  }

  // Show forgot password dialog
  void _forgotPasswordFlow() async {
    // This will send a password reset email (Firebase Auth built-in)
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: widget.email);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Password reset email sent to ${widget.email}"), backgroundColor: Colors.green),
      );
      setState(() {
        _showForgotPassword = false;
      });
    } catch (e) {
      setState(() {
        _error = "Failed to send reset email: ${e.toString()}";
      });
    }
  }

  // Show dialog after password change
  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: backgroundTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 32),
            SizedBox(width: 10),
            Text("Password Changed!", style: TextStyle(color: Colors.green)),
          ],
        ),
        content: Text(
          "You have successfully changed your password!\n\nFor security purposes, you need to login again.",
          style: TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: accentColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              // Sign out and redirect to login
              await FirebaseAuth.instance.signOut();
              Navigator.of(ctx).pop(); // Close dialog
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => LoginPage(showSecurityMessage: true)),
                    (Route<dynamic> route) => false,
              );
            },
            child: Text("Login Again"),
          ),
        ],
      ),
    );
  }

  void _resendOtp() {
    _sendOtp();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Change Account Password"),
        backgroundColor: backgroundTop,
        elevation: 0,
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [backgroundTop, backgroundBottom],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 28,
                              backgroundColor: accentColor,
                              child: Icon(Icons.account_circle, color: Colors.white, size: 32),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.username,
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  Text(
                                    widget.email,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        Text(
                          "Change your password securely.",
                          style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16, color: accentColor,
                          ),
                        ),
                        const SizedBox(height: 18),
                        if (!_isOtpSent)
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: accentColor,
                              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 3,
                            ),
                            icon: Icon(Icons.email, color: Colors.white),
                            label: Text(
                              "Send OTP to Email",
                              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 16),
                            ),
                            onPressed: _isLoading ? null : _sendOtp,
                          ),
                        if (_isOtpSent) ...[
                          const SizedBox(height: 16),
                          TextField(
                            controller: _otpController,
                            decoration: InputDecoration(
                              labelText: "Enter OTP",
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.08),
                              labelStyle: TextStyle(color: accentColor),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            keyboardType: TextInputType.number,
                            style: TextStyle(color: Colors.white),
                          ),
                          const SizedBox(height: 18),
                          TextField(
                            controller: _oldPasswordController,
                            decoration: InputDecoration(
                              labelText: "Current Password",
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.08),
                              labelStyle: TextStyle(color: accentColor),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            obscureText: true,
                            style: TextStyle(color: Colors.white),
                          ),
                          const SizedBox(height: 18),
                          TextField(
                            controller: _newPasswordController,
                            decoration: InputDecoration(
                              labelText: "New Password",
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.08),
                              labelStyle: TextStyle(color: accentColor),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            obscureText: true,
                            style: TextStyle(color: Colors.white),
                          ),
                          const SizedBox(height: 18),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: accentColor,
                              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 3,
                            ),
                            icon: Icon(Icons.lock_reset, color: Colors.white),
                            label: Text(
                              "Change Password",
                              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 16),
                            ),
                            onPressed: _isLoading ? null : _changePassword,
                          ),
                          const SizedBox(height: 18),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (!_isResendEnabled)
                                Text(
                                  "Resend OTP in ${_formatTime(_remainingTime)}",
                                  style: TextStyle(color: Colors.white70),
                                ),
                              if (_isResendEnabled)
                                TextButton(
                                  onPressed: _resendOtp,
                                  child: Text("Resend OTP", style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                                ),
                            ],
                          ),
                          if (_showForgotPassword)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Center(
                                child: TextButton(
                                  onPressed: _forgotPasswordFlow,
                                  child: Text(
                                    "Forgot Password?",
                                    style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                ),
                              ),
                            ),
                        ],
                        if (_error != null) ...[
                          SizedBox(height: 16),
                          Text(_error!, style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                        ],
                        if (_isLoading)
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Center(child: CircularProgressIndicator(color: accentColor)),
                          ),
                        const SizedBox(height: 10),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}