// main.dart
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ictrl/playerdashboard.dart';
import 'dart:async';
import 'dart:io';
import 'useragreement.dart';
import 'onboarding.dart';
import 'login.dart';
import 'paireddevice.dart';
import 'parentdashboard.dart';
import 'services/background_game_monitor.dart';
import 'package:workmanager/workmanager.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
void enhancedCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {

    try {
      WidgetsFlutterBinding.ensureInitialized();
      await Firebase.initializeApp();
      switch (task) {
        case EnhancedBackgroundGameMonitor.ENHANCED_MONITOR_TASK:
          await EnhancedBackgroundGameMonitor.checkEnhancedGamesInBackground(inputData: inputData);
          break;

        case 'gameMonitorTask': // ← THIS IS THE MISSING CASE
          await EnhancedBackgroundGameMonitor.checkEnhancedGamesInBackground(inputData: inputData);
          break;

        case 'enhancedGameMonitorTask':
          await EnhancedBackgroundGameMonitor.checkEnhancedGamesInBackground(inputData: inputData);
          break;

        default:
          print('🎮 ❌ Unknown enhanced background task: $task');
          print('🔍 Expected tasks: ${EnhancedBackgroundGameMonitor.ENHANCED_MONITOR_TASK}, gameMonitorTask, enhancedGameMonitorTask');
          return Future.value(false);
      }
      return Future.value(true);
    } catch (e) {
      print('🎮 ❌ Enhanced background task error: $e');
      return Future.value(false);
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kIsWeb) {
    await Firebase.initializeApp(options: FirebaseOptions(
        apiKey: "YOURKEY",
        authDomain: "YOURDOMAIN",
        projectId: "YOURPROJECT",
        storageBucket: "",
        messagingSenderId: "",
        appId: ""));
  } else {
    await Firebase.initializeApp();
  }
  try {

    // Initialize WorkManager
    await Workmanager().initialize(
      enhancedCallbackDispatcher,
      isInDebugMode: true, // Set to false in production
    );

    // Initialize notification service
    await GameplayNotificationService.initialize();

    // Initialize background game monitor
    await EnhancedBackgroundGameMonitor.initialize();

    print('🎮 ✅ Background monitoring initialized successfully');
  } catch (e) {
    print('🎮 ❌ Failed to initialize background monitoring: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iCtrl',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Roboto',
      ),
      home: const SplashScreen(),
      routes: {
        '/welcome': (context) => const WelcomePage(),
        '/onboarding': (context) => const OnboardingPage(),
        '/useragreement': (context) => const UserAgreementPage(),
        '/login': (context) => const LoginPage(),
        '/paireddevice': (context) => PairedDeviceScreen(),
        '/parentdashboard': (context) => ParentDashboard(),
        '/playerdashboard': (context) => PlayerDashboard(),
      },
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoController;
  late AnimationController _loadingController;
  late Animation<double> _logoAnimation;
  late Animation<double> _loadingAnimation;

  bool _isConnected = false;
  bool _isLoading = true;
  String _loadingText = "Checking connection...";

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();

    // Logo fade animation
    _logoController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _logoAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _logoController,
      curve: Curves.easeInOut,
    ));

    // Loading animation
    _loadingController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );

    _loadingAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _loadingController,
      curve: Curves.easeInOut,
    ));

    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Start logo animation
    _logoController.forward();

    // Wait for logo animation to complete
    await Future.delayed(const Duration(milliseconds: 1500));

    // Start loading animation
    _loadingController.forward();

    // Check connectivity
    await _checkConnectivity();

    // Only navigate if connected or user chose to continue anyway
    // The navigation is now handled within _checkConnectivity() method
  }

  Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
    // Handle background notification
    print("FCM Background message: ${message.messageId}");
    // Optionally show a local notification here
  }

  void initializeFCM() async {
    await FirebaseMessaging.instance.requestPermission();

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('FCM Foreground message: ${message.notification?.title}');
      // Show a local notification
      if (message.notification != null) {
        flutterLocalNotificationsPlugin.show(
          message.data.hashCode,
          message.notification!.title,
          message.notification!.body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              'parent_channel', 'Parent Notifications',
              importance: Importance.max,
              priority: Priority.high,
            ),
          ),
        );
      }
    });

    // Notification tap handler
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('Notification opened: ${message.data}');
      // Navigate to relevant screen if needed
    });

    // Get and save FCM token
    String? token = await FirebaseMessaging.instance.getToken();
    print('FCM Token: $token');
    // Save token to Firestore under parent profile/device
  }

  Future<void> _checkConnectivity() async {
    setState(() {
      _loadingText = "Checking internet connection...";
    });

    bool hasInternet = await _checkInternetConnection();

    setState(() {
      _isConnected = hasInternet;
      _loadingText = hasInternet ? "Connected!" : "No internet connection";
    });

    if (_isConnected) {
      // Check device info and Firestore document
      await _checkDeviceAndNavigate();
    } else {
      // If no connection, show retry option and don't navigate
      await _showNoConnectionDialog();
    }
  }

  Future<void> _checkDeviceAndNavigate() async {
    setState(() {
      _loadingText = "Checking device information...";
    });

    try {
      // Get device info
      Map<String, dynamic> currentDeviceInfo = await _getDeviceInfo();

      setState(() {
        _loadingText = "Verifying device registration...";
      });

      // Check if device is registered as a parent account
      bool isParentDeviceRegistered = await _checkDeviceInFirestore(currentDeviceInfo, 'parent_account');


      // Check if device is registered as a player account
      bool isPlayerDeviceRegistered = await _checkDeviceInFirestore(currentDeviceInfo, 'player_account');


      setState(() {
        if (isParentDeviceRegistered) {
          _loadingText = "Parent account verified!";
        } else if (isPlayerDeviceRegistered) {
          _loadingText = "Player account verified!";
        } else {
          _loadingText = "Setting up device...";
        }
      });

      // Wait a bit for better UX
      await Future.delayed(const Duration(milliseconds: 1000));

      if (mounted) {
        if (isParentDeviceRegistered) {

          // Device is registered as parent, go to parent dashboard
          Navigator.pushReplacementNamed(context, '/parentdashboard');
        } else if (isPlayerDeviceRegistered) {

          // Device is registered as player, go to login
          Navigator.pushReplacementNamed(context, '/login');
        } else {
          print('DEBUG: Navigating to welcome');
          // Device is not registered, go to welcome/onboarding
          Navigator.pushReplacementNamed(context, '/welcome');
        }
      }
    } catch (e) {
      setState(() {
        _loadingText = "Error checking device information";
      });

      // If there's an error, default to welcome page
      await Future.delayed(const Duration(milliseconds: 1000));
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/welcome');
      }
    }
  }

  Future<Map<String, dynamic>> _getDeviceInfo() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    Map<String, dynamic> deviceData = {};

    try {
      if (kIsWeb) {
        WebBrowserInfo webInfo = await deviceInfo.webBrowserInfo;
        deviceData = {
          'platform': 'web',
          'userAgent': webInfo.userAgent ?? 'unknown_web',
          'browserName': webInfo.browserName.toString(),
          'platform_os': webInfo.platform ?? 'unknown',
        };
      } else if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        deviceData = {
          'platform': 'android',
          'androidId': androidInfo.id,
          'brand': androidInfo.brand,
          'device': androidInfo.device,
          'fingerprint': androidInfo.fingerprint,
          'hardware': androidInfo.hardware,
          'model': androidInfo.model,
          'manufacturer': androidInfo.manufacturer,
          'isPhysicalDevice': androidInfo.isPhysicalDevice,
        };
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        deviceData = {
          'platform': 'ios',
          'identifierForVendor': iosInfo.identifierForVendor ?? 'unknown_ios',
          'name': iosInfo.name,
          'model': iosInfo.model,
          'systemName': iosInfo.systemName,
          'systemVersion': iosInfo.systemVersion,
          'isPhysicalDevice': iosInfo.isPhysicalDevice,
        };
      } else if (Platform.isWindows) {
        WindowsDeviceInfo windowsInfo = await deviceInfo.windowsInfo;
        deviceData = {
          'platform': 'windows',
          'deviceId': windowsInfo.deviceId,
          'computerName': windowsInfo.computerName,
          'userName': windowsInfo.userName,
        };
      } else if (Platform.isMacOS) {
        MacOsDeviceInfo macInfo = await deviceInfo.macOsInfo;
        deviceData = {
          'platform': 'macos',
          'systemGUID': macInfo.systemGUID ?? 'unknown_mac',
          'model': macInfo.model,
          'computerName': macInfo.computerName,
        };
      } else if (Platform.isLinux) {
        LinuxDeviceInfo linuxInfo = await deviceInfo.linuxInfo;
        deviceData = {
          'platform': 'linux',
          'machineId': linuxInfo.machineId ?? 'unknown_linux',
          'name': linuxInfo.name,
          'version': linuxInfo.version,
        };
      }
    } catch (e) {
      // Fallback device data if device info fails
      deviceData = {
        'platform': 'unknown',
        'fallback_id': 'fallback_${DateTime.now().millisecondsSinceEpoch}',
        'error': e.toString(),
      };
    }

    return deviceData;
  }

  Future<bool> _checkDeviceInFirestore(Map<String, dynamic> currentDeviceInfo, String collectionName) async {
    try {
      FirebaseFirestore firestore = FirebaseFirestore.instance;

      // Get all documents in the specified collection
      QuerySnapshot querySnapshot = await firestore
          .collection(collectionName)
          .get();

      // Check each document for matching device info
      for (QueryDocumentSnapshot doc in querySnapshot.docs) {
        Map<String, dynamic> docData = doc.data() as Map<String, dynamic>;

        // For parent_account, check parentDeviceId field (it's a string, not a Map)
        if (collectionName == 'parent_account') {
          if (docData.containsKey('parentDeviceId') && docData['parentDeviceId'] is String) {
            String storedDeviceId = docData['parentDeviceId'] as String;

            // Compare device ID string with current device's unique identifier
            bool isMatch = _compareParentDeviceId(currentDeviceInfo, storedDeviceId);

            if (isMatch) {
              return true;
            }
          } else {
            print('DEBUG: Document ${doc.id} does not have valid parentDeviceId field');
          }
        }
        // For player_account, check deviceInfo field (existing logic)
        else if (collectionName == 'player_account') {
          if (docData.containsKey('deviceInfo') && docData['deviceInfo'] is Map) {
            Map<String, dynamic> storedDeviceInfo = docData['deviceInfo'] as Map<String, dynamic>;

            // Compare device info
            bool isMatch = _compareDeviceInfo(currentDeviceInfo, storedDeviceInfo);

            if (isMatch) {
              return true;
            }
          } else {
            print('DEBUG: Document ${doc.id} does not have valid deviceInfo field');
          }
        }
      }
      return false;
    } catch (e) {
      print('Error checking device in Firestore ($collectionName): $e');
      return false;
    }
  }

  bool _compareParentDeviceId(Map<String, dynamic> current, String storedDeviceId) {
    // Get the current device's unique identifier based on platform
    String currentPlatform = current['platform'] ?? '';
    String currentDeviceId = '';

    switch (currentPlatform) {
      case 'android':
      // For Android, use androidId or a combination of identifiers
        currentDeviceId = current['androidId'] ?? '';
        break;

      case 'ios':
      // For iOS, use identifierForVendor
        currentDeviceId = current['identifierForVendor'] ?? '';
        break;

      case 'web':
      // For web, use userAgent or create a unique identifier
        currentDeviceId = current['userAgent'] ?? '';
        break;

      case 'windows':
      // For Windows, use deviceId
        currentDeviceId = current['deviceId'] ?? '';
        break;

      case 'macos':
      // For macOS, use systemGUID
        currentDeviceId = current['systemGUID'] ?? '';
        break;

      case 'linux':
      // For Linux, use machineId
        currentDeviceId = current['machineId'] ?? '';
        break;

      default:
      // For unknown platforms, use fallback_id if available
        currentDeviceId = current['fallback_id'] ?? '';
        break;
    }

    // If the stored device ID has a "parent_" prefix, remove it for comparison
    String cleanStoredDeviceId = storedDeviceId;
    if (storedDeviceId.startsWith('parent_')) {
      cleanStoredDeviceId = storedDeviceId.substring(7); // Remove "parent_"
    }

    // Compare the current device ID with the cleaned stored device ID
    return currentDeviceId.isNotEmpty && currentDeviceId == cleanStoredDeviceId;
  }

  bool _compareDeviceInfo(Map<String, dynamic> current, Map<String, dynamic> stored) {
    // Compare based on platform
    String currentPlatform = current['platform'] ?? '';

    switch (currentPlatform) {
      case 'android':
      // For Android, compare androidId, fingerprint, and hardware
        return current['androidId'] == stored['androidId'] &&
            current['fingerprint'] == stored['fingerprint'] &&
            current['hardware'] == stored['hardware'];

      case 'ios':
      // For iOS, compare identifierForVendor and model
        return current['identifierForVendor'] == stored['identifierForVendor'] &&
            current['model'] == stored['model'];

      case 'web':
      // For web, compare userAgent
        return current['userAgent'] == stored['userAgent'];

      case 'windows':
      // For Windows, compare deviceId
        return current['deviceId'] == stored['deviceId'];

      case 'macos':
      // For macOS, compare systemGUID
        return current['systemGUID'] == stored['systemGUID'];

      case 'linux':
      // For Linux, compare machineId
        return current['machineId'] == stored['machineId'];

      default:
        return false;
    }
  }

  Future<bool> _checkInternetConnection() async {
    try {
      // For web platform
      if (kIsWeb) {
        return await _checkWebConnection();
      }

      // For mobile platforms - try multiple reliable endpoints
      final List<String> testUrls = [
        'google.com',
        'cloudflare.com',
        '8.8.8.8', // Google DNS
        'firebase.google.com',
      ];

      for (String url in testUrls) {
        try {
          final result = await InternetAddress.lookup(url)
              .timeout(const Duration(seconds: 5));

          if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
            // Double check with HTTP request
            final client = HttpClient();
            final request = await client.getUrl(Uri.parse('https://$url'))
                .timeout(const Duration(seconds: 5));
            final response = await request.close()
                .timeout(const Duration(seconds: 5));
            client.close();

            if (response.statusCode == 200) {
              return true;
            }
          }
        } catch (e) {
          // Continue to next URL if this one fails
          continue;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> _checkWebConnection() async {
    try {
      // For web, we'll use a simple fetch to test connectivity
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('https://www.google.com'))
          .timeout(const Duration(seconds: 8));
      final response = await request.close()
          .timeout(const Duration(seconds: 8));
      client.close();

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<void> _showNoConnectionDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2D3142),
          title: const Text(
            'No Internet Connection',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'This app requires an internet connection to function properly. Please check your connection and try again.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _retryConnection();
              },
              child: const Text(
                'Retry',
                style: TextStyle(color: Color(0xFFE8956C)),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _retryConnection() async {
    setState(() {
      _isLoading = true;
      _loadingText = "Retrying...";
    });

    await _checkConnectivity();

    // Navigation is now handled within _checkConnectivity()
    // No need to navigate here as it's handled based on connection status
  }

  @override
  void dispose() {
    _logoController.dispose();
    _loadingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          child: Column(
            children: [
              // Logo area
              Expanded(
                flex: 3,
                child: Center(
                  child: AnimatedBuilder(
                    animation: _logoAnimation,
                    builder: (context, child) {
                      return Opacity(
                        opacity: _logoAnimation.value,
                        child: Transform.scale(
                          scale: 0.8 + (_logoAnimation.value * 0.2),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // App Logo
                              Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(30),
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFFE8956C), // Warm orange
                                      Color(0xFFD4794A), // Darker orange
                                    ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.3),
                                      blurRadius: 20,
                                      offset: const Offset(0, 10),
                                    ),
                                  ],
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
                              const SizedBox(height: 30),
                              // App Name
                              const Text(
                                'iCtrl',
                                style: TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: 2,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Family Safety Control',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white.withOpacity(0.7),
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Loading area
              Expanded(
                flex: 1,
                child: AnimatedBuilder(
                  animation: _loadingAnimation,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _loadingAnimation.value,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Loading indicator
                          SizedBox(
                            width: 30,
                            height: 30,
                            child: CircularProgressIndicator(
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Color(0xFFE8956C),
                              ),
                              strokeWidth: 3,
                            ),
                          ),
                          const SizedBox(height: 20),
                          // Loading text
                          Text(
                            _loadingText,
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.white.withOpacity(0.8),
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Connection status
                          if (_isConnected)
                            const Icon(
                              Icons.check_circle,
                              color: Colors.green,
                              size: 20,
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WelcomePage extends StatelessWidget {
  const WelcomePage({Key? key}) : super(key: key);

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
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () => _onWillPop(context),
      child: Scaffold(
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
            child: Column(
              children: [
                // Top illustration area
                Expanded(
                  flex: 3,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Illustration container
                        Container(
                          width: 300,
                          height: 250,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFFE8956C), // Warm orange
                                Color(0xFFD4794A), // Darker orange
                              ],
                            ),
                          ),
                          child: Stack(
                            children: [
                              // Background elements
                              Positioned(
                                right: 20,
                                top: 20,
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                              // Main illustration
                              Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.family_restroom,
                                      size: 80,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(height: 20),
                                    // Family silhouettes
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        _buildFamilyMember(30),
                                        const SizedBox(width: 10),
                                        _buildFamilyMember(25),
                                        const SizedBox(width: 10),
                                        _buildFamilyMember(20),
                                        const SizedBox(width: 10),
                                        _buildFamilyMember(15),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              // Decorative elements
                              Positioned(
                                left: 15,
                                bottom: 15,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 30,
                                bottom: 40,
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.7),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Content area
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          "Welcome to iCtrl!",
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          "The smart way to ensure your children's safety in the digital world.",
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white.withOpacity(0.8),
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
                // Bottom Get Started Button
                Padding(
                  padding: const EdgeInsets.all(30),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pushNamed(context, '/onboarding');
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE8956C),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                      ),
                      child: const Text(
                        'Get Started',
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
  }

  Widget _buildFamilyMember(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.8),
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Icon(
        Icons.person,
        size: size * 0.7,
        color: const Color(0xFF2D3142),
      ),
    );
  }
}

class AppLifecycleWrapper extends StatefulWidget {
  final Widget child;

  const AppLifecycleWrapper({Key? key, required this.child}) : super(key: key);

  @override
  _AppLifecycleWrapperState createState() => _AppLifecycleWrapperState();
}

class _AppLifecycleWrapperState extends State<AppLifecycleWrapper>
    with WidgetsBindingObserver {

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    print('🎮 App lifecycle changed: $state');

    switch (state) {
      case AppLifecycleState.paused:
      // App moved to background - ensure monitoring continues
        print('🎮 App paused - background monitoring should continue');
        break;

      case AppLifecycleState.resumed:
      // App resumed - reinitialize if needed
        print('🎮 App resumed - checking background monitoring status');
        _checkBackgroundMonitoringStatus();
        break;

      case AppLifecycleState.detached:
      // App is being terminated
        print('🎮 App detached - cleaning up background monitoring');
        EnhancedBackgroundGameMonitor.stopEnhancedMonitoring();
        break;

      default:
        break;
    }
  }

  void _checkBackgroundMonitoringStatus() {
    // This method can be used to verify background monitoring is still active
    // and restart it if necessary when the app resumes
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

}
