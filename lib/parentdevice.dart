import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';
import 'dart:async';
import 'dart:io';

class ParentDevicePage extends StatefulWidget {
  final String? initialDeviceId;
  final Map<String, dynamic>? initialDeviceInfo;

  const ParentDevicePage({
    super.key,
    this.initialDeviceId,
    this.initialDeviceInfo,
  });

  @override
  State<ParentDevicePage> createState() => _ParentDevicePageState();
}

class _ParentDevicePageState extends State<ParentDevicePage> {
  String _connectionId = '';
  String _deviceId = '';
  bool _isGeneratingCode = false;
  bool _isWaitingForConnection = false;
  bool _isDocumentCreated = false;
  StreamSubscription<DocumentSnapshot>? _connectionListener;
  String _errorMessage = '';
  Map<String, dynamic> _deviceInfo = {};

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();

  // SharedPreferences keys
  static const String _connectionIdKey = 'parent_connection_id';
  static const String _deviceIdKey = 'parent_device_id';

  @override
  void initState() {
    super.initState();
    _initializeConnection();
  }

  @override
  void dispose() {
    _connectionListener?.cancel();
    super.dispose();
  }

  Future<void> _initializeConnection() async {
    // Always get device info regardless of whether device ID exists
    await _getDeviceId();
    await _loadOrGenerateConnectionId();
    await _loadOrCreateDeviceId();
    await _setupFirestoreDocument();
  }

  Future<void> _loadOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();

    // Try to load existing device ID first
    String? savedDeviceId = prefs.getString(_deviceIdKey);

    if (savedDeviceId != null && savedDeviceId.isNotEmpty) {
      print('Loaded existing device ID: $savedDeviceId');
      setState(() {
        _deviceId = savedDeviceId;
      });
      // Don't return here - we still need to get device info
    }
  }

  Future<void> _loadOrGenerateConnectionId() async {
    final prefs = await SharedPreferences.getInstance();

    // Try to load existing connection ID first
    String? savedConnectionId = prefs.getString(_connectionIdKey);

    if (savedConnectionId != null && savedConnectionId.isNotEmpty) {
      print('Loaded existing connection ID: $savedConnectionId');
      setState(() {
        _connectionId = savedConnectionId;
      });
      return;
    }

    // Generate new connection ID if none exists
    _generateConnectionId();

    // Save the new connection ID
    await prefs.setString(_connectionIdKey, _connectionId);
    print('Saved new connection ID: $_connectionId');
  }

  Future<void> _getDeviceId() async {
    try {
      String deviceId = '';
      Map<String, dynamic> deviceInfo = {};

      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await _deviceInfoPlugin.androidInfo;
        // Use Android ID (unique per app installation)
        deviceId = androidInfo.id;

        // Store device info
        deviceInfo = {
          'platform': 'Android',
          'model': androidInfo.model,
          'manufacturer': androidInfo.manufacturer,
          'androidId': androidInfo.id,
          'brand': androidInfo.brand,
          'device': androidInfo.device,
          'deviceName': '${androidInfo.manufacturer} ${androidInfo.model}',
          'systemVersion': androidInfo.version.release,
        };

        print('Android Device Info:');
        print('- Model: ${androidInfo.model}');
        print('- Manufacturer: ${androidInfo.manufacturer}');
        print('- Android ID: ${androidInfo.id}');
        print('- Brand: ${androidInfo.brand}');
        print('- Device: ${androidInfo.device}');

      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await _deviceInfoPlugin.iosInfo;
        // Use identifierForVendor (unique per app vendor)
        deviceId = iosInfo.identifierForVendor ?? 'ios_${DateTime.now().millisecondsSinceEpoch}';

        // Store device info
        deviceInfo = {
          'platform': 'iOS',
          'name': iosInfo.name,
          'model': iosInfo.model,
          'systemName': iosInfo.systemName,
          'systemVersion': iosInfo.systemVersion,
          'identifierForVendor': iosInfo.identifierForVendor,
          'deviceName': '${iosInfo.name}',
        };

        print('iOS Device Info:');
        print('- Name: ${iosInfo.name}');
        print('- Model: ${iosInfo.model}');
        print('- SystemName: ${iosInfo.systemName}');
        print('- SystemVersion: ${iosInfo.systemVersion}');
        print('- IdentifierForVendor: ${iosInfo.identifierForVendor}');

      } else {
        // Fallback for other platforms
        deviceId = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
        deviceInfo = {
          'platform': 'Unknown',
          'deviceName': 'Unknown Device',
          'model': 'Unknown',
        };
      }

      // Always update device info, but only update device ID if it wasn't already loaded
      setState(() {
        // Only update device ID if it's empty (not loaded from SharedPreferences)
        if (_deviceId.isEmpty) {
          _deviceId = 'parent_$deviceId';
        }
        // Always update device info
        _deviceInfo = deviceInfo;
      });

      print('Device ID: $_deviceId');
      print('Device Info: $_deviceInfo');

      // Save device ID to SharedPreferences if it's new
      if (!_deviceId.contains('parent_$deviceId') || _deviceId.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_deviceIdKey, _deviceId);
        print('Saved device ID: $_deviceId');
      }

    } catch (e) {
      print('Error getting device info: $e');
      // Fallback to timestamp-based ID
      setState(() {
        if (_deviceId.isEmpty) {
          _deviceId = 'parent_${DateTime.now().millisecondsSinceEpoch}';
        }
        _deviceInfo = {
          'platform': 'Unknown',
          'deviceName': 'Unknown Device',
          'model': 'Unknown',
        };
      });
    }
  }

  String _generateConnectionId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random();

    // Generate random code
    String randomCode = '';
    for (int i = 0; i < 11; i++) {
      randomCode += chars[random.nextInt(chars.length)];
    }

    _connectionId = 'ICTRL-$randomCode';
    print('Generated connection ID: $_connectionId');
    return _connectionId;
  }

  Future<void> _setupFirestoreDocument() async {
    setState(() {
      _isWaitingForConnection = true;
      _isDocumentCreated = false;
      _errorMessage = '';
    });

    try {
      print('Creating Firestore document for: $_connectionId');
      print('Using device ID: $_deviceId');
      print('Device info being stored: $_deviceInfo'); // Debug print

      // Check if document already exists
      final existingDoc = await _firestore.collection('paired_devices').doc(_connectionId).get();
      if (existingDoc.exists) {
        print('Document already exists, checking status...');
        final data = existingDoc.data() as Map<String, dynamic>;

        // If already connected, navigate to paired device screen
        if (data['childDeviceId'] != null && data['status'] == 'connected') {
          print('Already connected to child device, navigating...');

          // FIXED: Pass the correct device info based on device type
          Navigator.pushReplacementNamed(
              context,
              '/paireddevice',
              arguments: {
                'connectionId': _connectionId,
                'deviceType': 'parent',
                'data': data,
                'deviceInfo': _deviceInfo, // Always pass current device info
                'parentDeviceInfo': _deviceInfo, // Explicitly pass parent info
                'childDeviceInfo': data['childDeviceInfo'], // Pass child info from Firestore
              }
          );
          return;
        }
      }

      // Prepare the data to be saved
      final connectionData = {
        'connectionId': _connectionId,
        'parentDeviceId': _deviceId,
        'parentDeviceInfo': _deviceInfo, // Store parent device info
        'childDeviceId': null,
        'childDeviceInfo': null, // Placeholder for child device info
        'status': 'waiting_for_child',
        'createdAt': FieldValue.serverTimestamp(),
        'connectedAt': null,
        'isActive': true,
      };

      print('Connection data being stored: $connectionData'); // Debug print

      // Create a batch to perform both operations atomically
      final batch = _firestore.batch();

      // Add to paired_devices collection
      final pairedDevicesRef = _firestore.collection('paired_devices').doc(_connectionId);
      batch.set(pairedDevicesRef, connectionData, SetOptions(merge: true));

      // Add to parent_account collection
      final parentAccountRef = _firestore.collection('parent_account').doc(_connectionId);
      batch.set(parentAccountRef, connectionData, SetOptions(merge: true));

      // Execute the batch
      await batch.commit();
      print('Documents created successfully in both collections');

      // Verify document was created in paired_devices
      final docCheck = await _firestore.collection('paired_devices').doc(_connectionId).get();
      if (docCheck.exists) {
        print('Document verification successful');
        final verifyData = docCheck.data() as Map<String, dynamic>;
        print('Verified data: $verifyData'); // Debug print

        setState(() {
          _isDocumentCreated = true;
        });

        // Start listening for child device connection
        _startListeningForConnection();
      } else {
        throw Exception('Document creation verification failed');
      }
    } catch (e) {
      print('Error setting up Firestore document: $e');
      setState(() {
        _errorMessage = 'Failed to create connection: $e';
        _isWaitingForConnection = false;
      });
      _showErrorDialog('Connection Setup Error',
          'Failed to create connection. Please try again.\n\nError: $e');
    }
  }

  void _startListeningForConnection() {
    if (_connectionId.isEmpty) return;

    print('Starting to listen for connection: $_connectionId');

    _connectionListener = _firestore
        .collection('paired_devices')
        .doc(_connectionId)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;

      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>;
        print('Connection status update: ${data['status']}');

        if (data['status'] == 'connected' && data['childDeviceId'] != null) {
          print('Child device connected! Navigating to paired device screen...');

          // Stop listening
          _connectionListener?.cancel();

          // Navigate to paired device screen
          Navigator.pushReplacementNamed(
              context,
              '/paireddevice',
              arguments: {
                'connectionId': _connectionId,
                'deviceType': 'parent',
                'data': data,
                'deviceInfo': _deviceInfo, // Always pass current device info
                'parentDeviceInfo': _deviceInfo, // Explicitly pass parent info
                'childDeviceInfo': data['childDeviceInfo'], // Pass child info from Firestore
              }
          );
        }
      } else {
        print('Connection document no longer exists');
        setState(() {
          _errorMessage = 'Connection expired. Please try again.';
          _isWaitingForConnection = false;
        });
      }
    }, onError: (error) {
      print('Error listening for connection: $error');
      setState(() {
        _errorMessage = 'Connection error: $error';
        _isWaitingForConnection = false;
      });
    });
  }

  Future<void> _regenerateCode() async {
    setState(() {
      _isGeneratingCode = true;
      _errorMessage = '';
    });

    // Cancel existing listener
    _connectionListener?.cancel();

    // Delete old document if it exists
    if (_connectionId.isNotEmpty) {
      _firestore.collection('paired_devices').doc(_connectionId).delete().catchError((e) {
        print('Error deleting old document: $e');
      });
    }

    // Clear stored connection ID but keep device ID
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_connectionIdKey);

    Future.delayed(const Duration(seconds: 1), () {
      setState(() {
        _isGeneratingCode = false;
      });
      _initializeConnection();
    });
  }

  void _navigateToParentDashboard() {
    // Cancel any existing listeners
    _connectionListener?.cancel();

    // Navigate to parent dashboard with necessary data
    Navigator.pushReplacementNamed(
        context,
        '/parentdashboard',
        arguments: {
          'connectionId': _connectionId,
          'deviceId': _deviceId,
          'deviceInfo': _deviceInfo,
          'deviceType': 'parent',
          'isStandalone': true, // Indicates this is running without child device
        }
    );
  }

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: _connectionId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Connection ID copied to clipboard'),
        backgroundColor: const Color(0xFFE8956C),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2E3A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Row(
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.red,
              size: 28,
            ),
            const SizedBox(width: 12),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: TextStyle(
            color: Colors.white.withOpacity(0.8),
            fontSize: 14,
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE8956C),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'OK',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
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
              // Header
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Parent device',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    // Options menu
                  ],
                ),
              ),

              // Main content
              Expanded(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: Column(
                      children: [
                        const SizedBox(height: 20),

                        // Title
                        const Text(
                          'Connect to the player device',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.white,
                            fontWeight: FontWeight.w400,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        // Error Message
                        if (_errorMessage.isNotEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            margin: const EdgeInsets.only(bottom: 20),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(15),
                              border: Border.all(
                                color: Colors.red.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.error_outline,
                                      color: Colors.red,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    const Text(
                                      'Error',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Colors.red,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _errorMessage,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.red,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // Connection Status
                        if (_isWaitingForConnection && _isDocumentCreated)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            margin: const EdgeInsets.only(bottom: 20),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8956C).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(15),
                              border: Border.all(
                                color: const Color(0xFFE8956C).withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Color(0xFFE8956C),
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 15),
                                const Text(
                                  'Waiting for device to connect...',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // Document Creation Status
                        if (_isWaitingForConnection && !_isDocumentCreated)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            margin: const EdgeInsets.only(bottom: 20),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(15),
                              border: Border.all(
                                color: Colors.blue.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.blue,
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 15),
                                const Text(
                                  'Setting up connection...',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // QR Code Section
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(30),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.2),
                              width: 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              // Orange cube icon to match theme
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFFE8956C), // Warm orange
                                      Color(0xFFD4794A), // Darker orange
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.view_in_ar,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),

                              const SizedBox(height: 30),

                              // QR Code
                              Container(
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: _isGeneratingCode || _connectionId.isEmpty
                                    ? const SizedBox(
                                  width: 200,
                                  height: 200,
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      color: Color(0xFFE8956C),
                                      strokeWidth: 3,
                                    ),
                                  ),
                                )
                                    : QrImageView(
                                  data: _connectionId,
                                  version: QrVersions.auto,
                                  size: 200,
                                  backgroundColor: Colors.white,
                                  foregroundColor: Colors.black,
                                ),
                              ),

                              const SizedBox(height: 20),

                              Text(
                                'Scan the QR code to pair to parent device',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white.withOpacity(0.8),
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 30),

                        // Connection ID Section
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.2),
                              width: 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Color(0xFFE8956C), // Warm orange
                                          Color(0xFFD4794A), // Darker orange
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(
                                      Icons.code,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Text(
                                    'Pairing code',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    onPressed: _connectionId.isEmpty ? null : _copyToClipboard,
                                    icon: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        gradient: _connectionId.isEmpty ? null : const LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            Color(0xFFE8956C), // Warm orange
                                            Color(0xFFD4794A), // Darker orange
                                          ],
                                        ),
                                        color: _connectionId.isEmpty ? Colors.grey : null,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Icon(
                                        Icons.copy,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 20),

                              // Connection ID Display
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 15,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.2),
                                    width: 1,
                                  ),
                                ),
                                child: Text(
                                  _connectionId.isEmpty ? 'Generating...' : _connectionId,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                    letterSpacing: 1.5,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),

                              const SizedBox(height: 15),

                              Text(
                                'Or enter this code manually on other device',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white.withOpacity(0.7),
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 30),

                        // Regenerate button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isGeneratingCode || _isWaitingForConnection ? null : _regenerateCode,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE8956C),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(25),
                              ),
                              elevation: 5,
                            ),
                            child: _isGeneratingCode
                                ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                                : const Text(
                              'Generate New Code',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 20),

                        // Maybe Later button
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: _navigateToParentDashboard,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white.withOpacity(0.7),
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(25),
                                side: BorderSide(
                                  color: Colors.white.withOpacity(0.3),
                                  width: 1,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.schedule,
                                  size: 18,
                                  color: Colors.white.withOpacity(0.7),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Maybe Later',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white.withOpacity(0.7),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}