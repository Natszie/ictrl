import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:async';
import 'dart:math';
import 'dart:io';

class EmailVerificationPage extends StatefulWidget {
  final String username;
  final String email;
  final String password;
  final DateTime birthdate;

  const EmailVerificationPage({
    Key? key,
    required this.username,
    required this.email,
    required this.password,
    required this.birthdate,
  }) : super(key: key);

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  final List<TextEditingController> _controllers = List.generate(6, (index) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(6, (index) => FocusNode());
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  Timer? _timer;
  Timer? _verificationTimer;
  int _remainingTime = 300; // 5 minutes in seconds
  bool _isResendEnabled = false;
  bool _isLoading = false;
  bool _hasShownInitialSnackBar = false;
  String _generatedOTP = '';
  bool _otpSent = false;

  // Device information variables
  Map<String, dynamic> _deviceData = {};

  @override
  void initState() {
    super.initState();
    _startTimer();
    _getDeviceInfo();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasShownInitialSnackBar) {
      _hasShownInitialSnackBar = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _sendVerificationEmail();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _verificationTimer?.cancel();
    for (var controller in _controllers) {
      controller.dispose();
    }
    for (var focusNode in _focusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }

  // Get device information
  Future<void> _getDeviceInfo() async {
    try {
      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await _deviceInfo.androidInfo;
        setState(() {
          _deviceData = {
            'platform': 'Android',
            'model': androidInfo.model,
            'brand': androidInfo.brand,
            'manufacturer': androidInfo.manufacturer,
            'device': androidInfo.device,
            'androidId': androidInfo.id,
            'version': androidInfo.version.release,
            'sdkInt': androidInfo.version.sdkInt,
            'isPhysicalDevice': androidInfo.isPhysicalDevice,
            'systemFeatures': androidInfo.systemFeatures,
            'product': androidInfo.product,
            'hardware': androidInfo.hardware,
            'fingerprint': androidInfo.fingerprint,
          };
        });
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await _deviceInfo.iosInfo;
        setState(() {
          _deviceData = {
            'platform': 'iOS',
            'model': iosInfo.model,
            'name': iosInfo.name,
            'systemName': iosInfo.systemName,
            'systemVersion': iosInfo.systemVersion,
            'localizedModel': iosInfo.localizedModel,
            'identifierForVendor': iosInfo.identifierForVendor,
            'isPhysicalDevice': iosInfo.isPhysicalDevice,
            'utsname': {
              'machine': iosInfo.utsname.machine,
              'nodename': iosInfo.utsname.nodename,
              'release': iosInfo.utsname.release,
              'sysname': iosInfo.utsname.sysname,
              'version': iosInfo.utsname.version,
            }
          };
        });
      }
    } catch (e) {
      print('Error getting device info: $e');
      setState(() {
        _deviceData = {
          'platform': 'Unknown',
          'error': 'Failed to get device information',
        };
      });
    }
  }

  void _startTimer() {
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

  // Generate a random 6-digit OTP
  String _generateOTP() {
    final random = Random();
    return List.generate(6, (_) => random.nextInt(10)).join();
  }

  // Send OTP via email using SMTP
  Future<void> _sendVerificationEmail() async {
    final smtpServer = gmail('ictrlinc@gmail.com', 'wydj cspi nsdz ljqc');

    // Generate OTP
    final otp = _generateOTP();
    setState(() {
      _generatedOTP = otp;
      _isLoading = true;
    });

    final message = Message()
      ..from = Address('parenteyeinc@gmail.com', 'iCtrl Verification')
      ..recipients.add(widget.email)
      ..subject = 'Your Verification Code'
      ..html = '''
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
        <div style="text-align: center; margin-bottom: 30px;">
          <h1 style="color: #E8956C; font-size: 28px; margin: 0;">Email Verification</h1>
        </div>
        
        <div style="background-color: #f8f9fa; padding: 30px; border-radius: 10px; margin-bottom: 20px;">
          <p style="font-size: 16px; color: #333; margin-bottom: 20px;">Hello ${widget.username},</p>
          <p style="font-size: 16px; color: #333; margin-bottom: 20px;">Your verification code is:</p>
          
          <div style="background-color: #2D3142; padding: 20px; border-radius: 8px; text-align: center; margin: 20px 0;">
            <h2 style="color: #E8956C; font-size: 32px; letter-spacing: 8px; margin: 0; font-weight: bold;">$otp</h2>
          </div>
          
          <p style="font-size: 14px; color: #666; margin-bottom: 10px;">This code will expire in 5 minutes.</p>
          <p style="font-size: 14px; color: #666;">If you didn't request this verification, please ignore this email.</p>
        </div>
        
        <div style="text-align: center; margin-top: 30px;">
          <p style="font-size: 14px; color: #999;">Thank you,<br>The iCtrl Team</p>
        </div>
      </div>
    ''';

    try {
      final sendReport = await send(message, smtpServer);
      print('Message sent: ${sendReport.toString()}');

      setState(() {
        _isLoading = false;
        _otpSent = true;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Verification code sent to ${widget.email}'),
            backgroundColor: const Color(0xFFE8956C),
          ),
        );
      }
    } catch (e) {
      print('Error sending email: $e');

      setState(() {
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send verification code: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _formatTime(int seconds) {
    int minutes = seconds ~/ 60;
    int remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  void _onCodeChanged(String value, int index) {
    if (value.length == 1) {
      if (index < 5) {
        _focusNodes[index + 1].requestFocus();
      }
    } else if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    }

    // Check if all fields are filled
    bool allFilled = _controllers.every((controller) => controller.text.isNotEmpty);
    if (allFilled) {
      _verifyCode();
    }
  }

  void _verifyCode() async {
    setState(() {
      _isLoading = true;
    });

    String enteredCode = _controllers.map((controller) => controller.text).join();
    print('Entered OTP: $enteredCode');
    print('Generated OTP: $_generatedOTP');

    // Verify the OTP
    if (enteredCode == _generatedOTP) {
      print('OTP verified successfully, creating Firebase account...');
      // OTP is correct, now create Firebase account and save data immediately
      await _createFirebaseAccountAndSaveData();
    } else {
      print('Invalid OTP entered');
      setState(() {
        _isLoading = false;
      });
      _showErrorDialog();
    }
  }

  Future<void> _createFirebaseAccountAndSaveData() async {
    try {
      print('Creating Firebase user account...');
      // Step 1: Create user with email and password
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: widget.email,
        password: widget.password,
      );

      print('Firebase user created with UID: ${userCredential.user!.uid}');

      // Step 2: Save user data to Firestore immediately after account creation
      await _saveUserDataToFirestore(userCredential.user!);

      // Step 3: Wait longer and force token refresh for auth state to be fully ready
      await Future.delayed(const Duration(seconds: 2));

      // Force token refresh to ensure permissions are updated
      await userCredential.user!.getIdToken(true); // true forces refresh
      print('Token refreshed');

      // Step 5: Send Firebase email verification (optional - for additional security)
      await userCredential.user!.sendEmailVerification();
      print('Firebase email verification sent');

      setState(() {
        _isLoading = false;
      });

      _showSuccessDialog();

    } catch (e) {
      print('Error creating Firebase account: $e');
      setState(() {
        _isLoading = false;
      });

      String errorMessage = 'Registration failed. Please try again.';
      if (e is FirebaseAuthException) {
        switch (e.code) {
          case 'email-already-in-use':
            errorMessage = 'This email is already registered.';
            break;
          case 'weak-password':
            errorMessage = 'Password is too weak.';
            break;
          case 'invalid-email':
            errorMessage = 'Invalid email address.';
            break;
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _saveUserDataToFirestore(User user) async {
    try {
      print('Saving user data to Firestore...');
      print('User UID: ${user.uid}');
      print('Username: ${widget.username}');
      print('Email: ${widget.email}');

      // Prepare device info for storage
      Map<String, dynamic> deviceInfo = Map.from(_deviceData);
      deviceInfo['registeredAt'] = Timestamp.now();

      // Create user document
      final userData = {
        'username': widget.username,
        'email': widget.email,
        'birthdate': Timestamp.fromDate(widget.birthdate),
        'createdAt': Timestamp.now(),
        'emailVerified': true, // Since we verified via OTP
        'deviceInfo': deviceInfo,
        'registrationDevice': deviceInfo, // Keep original registration device
      };

      print('User data to save: $userData');

      // Store user data in Firestore
      await _firestore.collection('player_account').doc(user.uid).set(userData);

      // Update the user's display name
      await user.updateDisplayName(widget.username);

      print('User data saved to Firestore successfully');
      print('Display name updated to: ${widget.username}');

      // Verify the document was created
      DocumentSnapshot doc = await _firestore.collection('player_account').doc(user.uid).get();
      if (doc.exists) {
        print('✅ Document verification: User document exists in Firestore');
        print('Document data: ${doc.data()}');
      } else {
        print('❌ Document verification: User document NOT found in Firestore');
        throw Exception('Failed to save user data to Firestore');
      }

    } catch (e) {
      print('❌ Error saving user data to Firestore: $e');
      print('Error type: ${e.runtimeType}');
      if (e is FirebaseException) {
        print('Firebase error code: ${e.code}');
        print('Firebase error message: ${e.message}');
      }
      throw e; // Re-throw to handle in calling method
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D3142),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Icon(
          Icons.check_circle,
          color: Colors.green,
          size: 60,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Account Created!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Your account has been created and verified successfully.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => _handleSuccessNavigation(),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE8956C),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  void _handleSuccessNavigation() {
    Navigator.of(context).pop(); // Close dialog
    Navigator.of(context).popUntil((route) => route.isFirst);
    Navigator.pushReplacementNamed(
      context,
      '/login',
      arguments: {
        'email': widget.email,
        'password': widget.password,
        'autoLogin': true, // Flag to indicate automatic login
      },
    );
  }

  void _showErrorDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D3142),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Icon(
          Icons.error,
          color: Colors.red,
          size: 60,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Invalid Code',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Please enter the correct verification code.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _clearCode();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE8956C),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  void _clearCode() {
    for (var controller in _controllers) {
      controller.clear();
    }
    _focusNodes[0].requestFocus();
  }

  void _resendCode() {
    setState(() {
      _remainingTime = 300;
      _isResendEnabled = false;
    });
    _startTimer();
    _sendVerificationEmail();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2D3142),
      resizeToAvoidBottomInset: true,
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight,
                  ),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 30),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const SizedBox(height: 40),
                          // Email icon
                          Container(
                            width: 100,
                            height: 100,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Color(0xFFE8956C),
                                  Color(0xFFD4794A),
                                ],
                              ),
                            ),
                            child: const Icon(
                              Icons.email,
                              size: 50,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 30),
                          // Title
                          const Text(
                            'Verify Your Email',
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),
                          // Subtitle
                          Text(
                            'We sent a verification code to\n${widget.email}',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.white.withOpacity(0.7),
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 40),
                          // Code input fields
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: List.generate(6, (index) {
                              return SizedBox(
                                width: 45,
                                height: 60,
                                child: TextFormField(
                                  controller: _controllers[index],
                                  focusNode: _focusNodes[index],
                                  textAlign: TextAlign.center,
                                  keyboardType: TextInputType.number,
                                  maxLength: 1,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  decoration: InputDecoration(
                                    counterText: '',
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
                                  ),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  onChanged: (value) => _onCodeChanged(value, index),
                                ),
                              );
                            }),
                          ),
                          const SizedBox(height: 30),
                          // Timer and resend section
                          if (!_isResendEnabled)
                            Text(
                              'Resend code in ${_formatTime(_remainingTime)}',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 14,
                              ),
                            )
                          else
                            TextButton(
                              onPressed: _resendCode,
                              child: const Text(
                                'Resend Code',
                                style: TextStyle(
                                  color: Color(0xFFE8956C),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          const Spacer(),
                          // Verify button
                          Padding(
                            padding: const EdgeInsets.only(bottom: 40),
                            child: SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : _verifyCode,
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
                                  'Verify Email',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
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
            },
          ),
        ),
      ),
    );
  }
}