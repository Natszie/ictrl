import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'signup.dart';
import 'playerdashboard.dart';
import 'parentdevice.dart';
import 'forgotPassword.dart';

class LoginPage extends StatefulWidget {
  final bool showSecurityMessage;
  const LoginPage({Key? key, this.showSecurityMessage = false}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _rememberMe = false;
  bool _isAutoLogin = false;
  bool _isLoading = false;

  // Firebase instances
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // User type selection
  String _selectedUserType = 'player';

  // Remember me expiration duration (14 days)
  static const int rememberMeDays = 14;

  @override
  void initState() {
    super.initState();
    _checkRememberMe();
    if (widget.showSecurityMessage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showSecurityDialog();
      });
    }
  }

  void _showSecurityDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2D3142),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Icon(
                Icons.security,
                color: Colors.orange,
                size: 28,
              ),
              const SizedBox(width: 10),
              const Text(
                'Security Notice',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Text(
            'You have successfully changed your password.\n\nFor your security, please log in again.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.9),
              fontSize: 16,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Check if arguments are passed from email verification
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

    if (args != null) {
      final email = args['email'] as String?;
      final password = args['password'] as String?;
      final autoLogin = args['autoLogin'] as bool?;

      if (email != null && password != null) {
        _emailController.text = email;
        _passwordController.text = password;
        _isAutoLogin = autoLogin ?? false;

        // If auto-login is enabled, trigger login after widget is built
        if (_isAutoLogin) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _handleAutoLogin();
          });
        }
      }
    }
  }

  // Check if remember me has expired
  bool _isRememberMeExpired(Timestamp? rememberMeTimestamp) {
    if (rememberMeTimestamp == null) return true;

    DateTime rememberMeDate = rememberMeTimestamp.toDate();
    DateTime currentDate = DateTime.now();
    Duration difference = currentDate.difference(rememberMeDate);

    return difference.inDays >= rememberMeDays;
  }

  // Check for remembered credentials on app start
  Future<void> _checkRememberMe() async {
    try {
      // Check if there's a current user
      User? currentUser = _auth.currentUser;

      if (currentUser != null) {
        // Get user document to check if remember me is enabled
        DocumentSnapshot userDoc = await _firestore
            .collection('player_account')
            .doc(currentUser.uid)
            .get();

        if (userDoc.exists) {
          Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
          bool rememberMeEnabled = userData['rememberMe'] ?? false;
          Timestamp? rememberMeTimestamp = userData['rememberMeTimestamp'];

          // Check if remember me is enabled and not expired
          if (rememberMeEnabled && !_isRememberMeExpired(rememberMeTimestamp)) {
            setState(() {
              _emailController.text = userData['email'] ?? '';
              _rememberMe = true;
              _isAutoLogin = true;
            });

            // Auto-login after widget is built
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _performAutoRememberLogin();
            });
          } else if (rememberMeEnabled && _isRememberMeExpired(rememberMeTimestamp)) {
            // Remember me has expired, clear it
            print('Remember me has expired (${rememberMeDays} days). Clearing...');
            await _clearRememberMe();

            // Show a message to the user
            WidgetsBinding.instance.addPostFrameCallback((_) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Auto-login has expired. Please login again.'),
                  backgroundColor: Colors.orange,
                  duration: Duration(seconds: 3),
                ),
              );
            });
          }
        }
      }
    } catch (e) {
      print('Error checking remember me: $e');
    }
  }

  // Auto-login for remembered users
  Future<void> _performAutoRememberLogin() async {
    setState(() {
      _isLoading = true;
    });

    try {
      User? currentUser = _auth.currentUser;

      if (currentUser != null) {
        // Double-check if remember me is still valid before auto-login
        DocumentSnapshot userDoc = await _firestore
            .collection('player_account')
            .doc(currentUser.uid)
            .get();

        if (userDoc.exists) {
          Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
          Timestamp? rememberMeTimestamp = userData['rememberMeTimestamp'];

          if (_isRememberMeExpired(rememberMeTimestamp)) {
            // Expired during the process, clear and don't auto-login
            await _clearRememberMe();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Auto-login has expired. Please login again.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
            return;
          }
        }

        // User is authenticated and remember me is still valid
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Welcome back!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => PlayerDashboard(),
          ),
        );
      }
    } catch (e) {
      print('Auto-login error: $e');
      // If auto-login fails, clear remember me
      await _clearRememberMe();
    } finally {
      setState(() {
        _isLoading = false;
        _isAutoLogin = false;
      });
    }
  }

  // Save remember me preference to Firebase with timestamp
  Future<void> _saveRememberMe(String userId, String email) async {
    try {
      await _firestore
          .collection('player_account')
          .doc(userId)
          .update({
        'rememberMe': _rememberMe,
        'rememberMeTimestamp': _rememberMe ? FieldValue.serverTimestamp() : null,
        'lastLogin': FieldValue.serverTimestamp(),
        'email': email, // Store email for auto-fill
      });
    } catch (e) {
      print('Error saving remember me: $e');
    }
  }

  // Clear remember me preference
  Future<void> _clearRememberMe() async {
    try {
      User? currentUser = _auth.currentUser;
      if (currentUser != null) {
        await _firestore
            .collection('player_account')
            .doc(currentUser.uid)
            .update({
          'rememberMe': false,
          'rememberMeTimestamp': null,
        });
      }
    } catch (e) {
      print('Error clearing remember me: $e');
    }
  }

  // Method to check and clean up expired remember me for all users (optional - for admin use)
  Future<void> _cleanupExpiredRememberMe() async {
    try {
      DateTime cutoffDate = DateTime.now().subtract(Duration(days: rememberMeDays));

      QuerySnapshot expiredUsers = await _firestore
          .collection('player_account')
          .where('rememberMe', isEqualTo: true)
          .where('rememberMeTimestamp', isLessThan: Timestamp.fromDate(cutoffDate))
          .get();

      for (QueryDocumentSnapshot doc in expiredUsers.docs) {
        await doc.reference.update({
          'rememberMe': false,
          'rememberMeTimestamp': null,
        });
      }

      print('Cleaned up ${expiredUsers.docs.length} expired remember me entries');
    } catch (e) {
      print('Error cleaning up expired remember me: $e');
    }
  }

  void _handleAutoLogin() async {
    setState(() {
      _isLoading = true;
    });

    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Logging in...'),
        backgroundColor: Color(0xFFE8956C),
        duration: Duration(seconds: 2),
      ),
    );

    // Validate form and proceed with login
    if (_formKey.currentState!.validate()) {
      await _performLogin();
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _performLogin() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Sign in with Firebase Auth
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      // Get user data from Firestore
      DocumentSnapshot userDoc = await _firestore
          .collection('player_account')
          .doc(userCredential.user!.uid)
          .get();

      if (userDoc.exists) {
        Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;

        // Save remember me preference if enabled
        if (_rememberMe) {
          await _saveRememberMe(userCredential.user!.uid, _emailController.text.trim());
        } else {
          // Clear remember me if disabled
          await _clearRememberMe();
        }

        // Success - navigate to dashboard
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Login successful!'),
            backgroundColor: Colors.green,
          ),
        );

        // Navigate to dashboard with user data
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => PlayerDashboard(),
          ),
        );
      } else {
        // User document doesn't exist in Firestore
        _showErrorDialog('Account not found. Please contact support.');
      }
    } on FirebaseAuthException catch (e) {
      String errorMessage = _getErrorMessage(e.code);
      _showErrorDialog(errorMessage);
    } catch (e) {
      _showErrorDialog('An unexpected error occurred. Please try again.');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  String _getErrorMessage(String errorCode) {
    switch (errorCode) {
      case 'user-not-found':
        return 'No account found with this email address.';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many login attempts. Please try again later.';
      case 'network-request-failed':
        return 'Network error. Please check your connection.';
      default:
        return 'Login failed. Please try again.';
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2D3142),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Icon(
                Icons.error_outline,
                color: Colors.red,
                size: 28,
              ),
              const SizedBox(width: 10),
              const Text(
                'Login Error',
                style: TextStyle(
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
              onPressed: () => Navigator.of(context).pop(),
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

  // Reset password functionality
  Future<void> _resetPassword() async {
    if (_emailController.text.isEmpty) {
      _showErrorDialog('Please enter your email address first.');
      return;
    }

    try {
      await _auth.sendPasswordResetEmail(email: _emailController.text.trim());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password reset email sent!'),
          backgroundColor: Colors.green,
        ),
      );
    } on FirebaseAuthException catch (e) {
      String errorMessage = _getErrorMessage(e.code);
      _showErrorDialog(errorMessage);
    }
  }

  Future<bool> _onWillPop(BuildContext context) async {
    return (await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Exit App'),
        content: const Text('Do you want to exit the app?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    )) ??
        false;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleLogin() {
    if (_selectedUserType == 'parent') {
      // Show confirmation dialog for parents
      _showParentConfirmationDialog();
    } else {
      // For players, validate form and authenticate
      if (_formKey.currentState!.validate()) {
        _performLogin();
      }
    }
  }

  void _showParentConfirmationDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2D3142),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Icon(
                Icons.family_restroom,
                color: const Color(0xFFE8956C),
                size: 28,
              ),
              const SizedBox(width: 10),
              const Text(
                'Parent Verification',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you a parent or guardian?',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 15),
              Text(
                'This section contains parental controls and monitoring features. Only parents or guardians should access this area.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.orange.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'This area is intended for adults only',
                        style: TextStyle(
                          color: Colors.orange.withOpacity(0.9),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 16,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop(); // Close the dialog first

                // Navigate directly to parent device page
                await _performParentLogin();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8956C),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
              child: const Text(
                'Yes, I am a Parent',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _performParentLogin() async {
    // Navigate directly to parent device page
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => const ParentDevicePage(), // Make sure to import parentdevice.dart
      ),
    );
  }

  // Add logout functionality to clear remember me
  Future<void> logout() async {
    try {
      await _clearRememberMe();
      await _auth.signOut();
    } catch (e) {
      print('Error during logout: $e');
    }
  }


  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () => _onWillPop(context),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF2D3142), // Dark blue-gray
                Color(0xFF1A1D2E), // Darker blue
              ],
            ),
          ),
          child: SafeArea(
            child: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  children: [
                    const SizedBox(height: 60),
                    // Logo/Icon section
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFFE8956C), // Warm orange
                            Color(0xFFD4794A), // Darker orange
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
                    // Welcome back text
                    Text(
                      _isAutoLogin ? "Welcome Back!" : "Welcome Back!",
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _isAutoLogin
                          ? "Logging you in automatically..."
                          : "Sign in to continue protecting your family",
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.white.withOpacity(0.7),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),

                    // User type selector
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(25),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                // Unfocus any active text fields and hide keyboard
                                FocusScope.of(context).unfocus();
                                setState(() {
                                  _selectedUserType = 'player';
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: _selectedUserType == 'player'
                                      ? const Color(0xFFE8956C)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.sports_esports,
                                      color: _selectedUserType == 'player'
                                          ? Colors.white
                                          : Colors.white.withOpacity(0.7),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Player',
                                      style: TextStyle(
                                        color: _selectedUserType == 'player'
                                            ? Colors.white
                                            : Colors.white.withOpacity(0.7),
                                        fontWeight: _selectedUserType == 'player'
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                // Unfocus any active text fields and hide keyboard
                                FocusScope.of(context).unfocus();
                                // Clear text field controllers when switching to parent
                                if (_selectedUserType == 'player') {
                                  _emailController.clear();
                                  _passwordController.clear();
                                }
                                setState(() {
                                  _selectedUserType = 'parent';
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: _selectedUserType == 'parent'
                                      ? const Color(0xFFE8956C)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.family_restroom,
                                      color: _selectedUserType == 'parent'
                                          ? Colors.white
                                          : Colors.white.withOpacity(0.7),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Parent',
                                      style: TextStyle(
                                        color: _selectedUserType == 'parent'
                                            ? Colors.white
                                            : Colors.white.withOpacity(0.7),
                                        fontWeight: _selectedUserType == 'parent'
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 30),

                    // Login form (show only for player)
                    if (_selectedUserType == 'player') ...[
                      Form(
                        key: _formKey,
                        child: Column(
                          children: [
                            // Email field
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
                                errorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(15),
                                  borderSide: const BorderSide(
                                    color: Colors.red,
                                    width: 2,
                                  ),
                                ),
                                focusedErrorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(15),
                                  borderSide: const BorderSide(
                                    color: Colors.red,
                                    width: 2,
                                  ),
                                ),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Please enter your email';
                                }
                                if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
                                  return 'Please enter a valid email';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 20),
                            // Password field
                            TextFormField(
                              controller: _passwordController,
                              obscureText: _obscurePassword,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                labelText: 'Password',
                                labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                                prefixIcon: Icon(
                                  Icons.lock_outline,
                                  color: Colors.white.withOpacity(0.7),
                                ),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword ? Icons.visibility_off : Icons.visibility,
                                    color: Colors.white.withOpacity(0.7),
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _obscurePassword = !_obscurePassword;
                                    });
                                  },
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
                                errorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(15),
                                  borderSide: const BorderSide(
                                    color: Colors.red,
                                    width: 2,
                                  ),
                                ),
                                focusedErrorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(15),
                                  borderSide: const BorderSide(
                                    color: Colors.red,
                                    width: 2,
                                  ),
                                ),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Please enter your password';
                                }
                                if (value.length < 6) {
                                  return 'Password must be at least 6 characters';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 20),
                            // Remember me and Forgot password row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Checkbox(
                                      value: _rememberMe,
                                      onChanged: (value) {
                                        setState(() {
                                          _rememberMe = value ?? false;
                                        });
                                      },
                                      activeColor: const Color(0xFFE8956C),
                                      checkColor: Colors.white,
                                    ),
                                    Text(
                                      'Remember me',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.7),
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                ),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ForgotPasswordPage()),
                  );
                },
                child: Text(
                    'Forgot Password?',
                  style: TextStyle(
                    color: const Color(0xFFE8956C),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                ),
              ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 30),
                    // Action button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: (_isAutoLogin || _isLoading) ? null : _handleLogin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE8956C),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(25),
                          ),
                          elevation: 5,
                        ),
                        child: (_isAutoLogin || _isLoading)
                            ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                            : Text(
                          _selectedUserType == 'player' ? 'Sign In' : 'Access Parent Dashboard',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                    if (_selectedUserType == 'player' && !_isAutoLogin) ...[
                      const SizedBox(height: 30),
                      // Divider
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 1,
                              color: Colors.white.withOpacity(0.3),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 15),
                            child: Text(
                              'OR',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Container(
                              height: 1,
                              color: Colors.white.withOpacity(0.3),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 30),
                      // Sign up prompt
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            "Don't have an account? ",
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 14,
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (context) => const SignupPage())
                              );
                            },
                            child: const Text(
                              'Sign Up',
                              style: TextStyle(
                                color: Color(0xFFE8956C),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}