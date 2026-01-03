import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:math';

class PairedDeviceScreen extends StatefulWidget {
  const PairedDeviceScreen({Key? key}) : super(key: key);

  @override
  State<PairedDeviceScreen> createState() => _PairedDeviceScreenState();
}

class _PairedDeviceScreenState extends State<PairedDeviceScreen>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;
  StreamSubscription<DocumentSnapshot>? _connectionListener;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Connection data from arguments
  String connectionId = '';
  String deviceType = '';
  Map<String, dynamic> connectionData = {};
  Map<String, dynamic> currentDeviceInfo = {}; // Info for the current device (this device)

  bool isConnecting = false;
  bool isConnected = false;
  bool showSuccess = false;
  String statusMessage = '';

  // Pairing delay variables
  Timer? _pairingTimer;
  int _pairingProgress = 0;
  List<String> _pairingSteps = [
    'Initializing connection...',
    'Discovering devices...',
    'Establishing secure handshake...',
    'Syncing device information...',
    'Verifying connection...',
    'Finalizing pairing...'
  ];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(
      begin: 0.8,
      end: 1.2,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));

    // Get the connection data from navigation arguments
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadArgumentsAndInitialize();
    });
  }

  void _loadArgumentsAndInitialize() {
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

    if (args != null) {
      setState(() {
        connectionId = args['connectionId'] ?? '';
        deviceType = args['deviceType'] ?? 'child';
        connectionData = args['data'] ?? {};
        currentDeviceInfo = args['deviceInfo'] ?? {}; // This is info for the current device

        // Store explicit parent and child device info if provided
        if (args['parentDeviceInfo'] != null) {
          // Ensure parent device info is stored in connection data
          connectionData['parentDeviceInfo'] = args['parentDeviceInfo'];
        }
        if (args['childDeviceInfo'] != null) {
          // Ensure child device info is stored in connection data
          connectionData['childDeviceInfo'] = args['childDeviceInfo'];
        }
      });

      print('Device Type: $deviceType'); // Debug print
      print('Current Device Info: $currentDeviceInfo'); // Debug print
      print('Parent Device Info: ${connectionData['parentDeviceInfo']}'); // Debug print
      print('Child Device Info: ${connectionData['childDeviceInfo']}'); // Debug print
      print('Connection data: $connectionData'); // Debug print

      // Start monitoring connection status
      _startConnectionMonitoring();

      // If already connected, show success
      if (connectionData['status'] == 'connected') {
        setState(() {
          isConnected = true;
          showSuccess = true;
          statusMessage = 'Successfully paired with ${deviceType == 'parent' ? 'child' : 'parent'} device!';
        });
      } else {
        // Start pairing process with delay
        _startPairingWithDelay();
      }
    } else {
      // Handle case where no arguments provided
      setState(() {
        statusMessage = 'Error: No connection data provided';
      });
    }
  }

  void _startPairingWithDelay() {
    setState(() {
      isConnecting = true;
      _pairingProgress = 0;
      statusMessage = _pairingSteps[0];
    });

    _animationController.repeat(reverse: true);

    // Generate random delay between 3-10 seconds
    final random = Random();
    final totalDelaySeconds = 3 + random.nextInt(8); // 3 to 10 seconds
    final stepDuration = totalDelaySeconds / _pairingSteps.length;

    print('Starting pairing process with ${totalDelaySeconds}s delay'); // Debug print

    // Start the step-by-step pairing process
    _pairingTimer = Timer.periodic(
      Duration(milliseconds: (stepDuration * 1000).round()),
          (timer) {
        if (_pairingProgress < _pairingSteps.length - 1) {
          setState(() {
            _pairingProgress++;
            statusMessage = _pairingSteps[_pairingProgress];
          });

          // Add haptic feedback for each step
          HapticFeedback.selectionClick();
        } else {
          // Pairing complete
          timer.cancel();
          _completePairingProcess();
        }
      },
    );
  }

  void _completePairingProcess() {
    // Update Firestore to mark as connected (if needed)
    if (connectionId.isNotEmpty) {
      _firestore.collection('paired_devices').doc(connectionId).update({
        'status': 'connected',
        'connectedAt': FieldValue.serverTimestamp(),
      }).catchError((error) {
        print('Error updating connection status: $error');
      });
    }

    setState(() {
      isConnecting = false;
      isConnected = true;
      showSuccess = true;
      statusMessage = 'Successfully connected to ${deviceType == 'parent' ? 'child' : 'parent'} device!';
    });

    _animationController.stop();
    HapticFeedback.heavyImpact();

    // Auto-navigate after showing success for 2 seconds
    Timer(const Duration(seconds: 2), () {
      if (mounted) {
        _completePairing();
      }
    });
  }

  void _startConnectionMonitoring() {
    if (connectionId.isNotEmpty) {
      _connectionListener = _firestore
          .collection('paired_devices')
          .doc(connectionId)
          .snapshots()
          .listen((snapshot) {
        if (snapshot.exists) {
          final data = snapshot.data() as Map<String, dynamic>;
          setState(() {
            connectionData = data;
          });

          // Check connection status - only if not currently in pairing process
          if (data['status'] == 'connected' && !isConnecting && !isConnected) {
            setState(() {
              isConnected = true;
              showSuccess = true;
              statusMessage = 'Successfully connected to ${deviceType == 'parent' ? 'child' : 'parent'} device!';
            });
            _animationController.stop();
            HapticFeedback.heavyImpact();
          } else if (data['status'] == 'disconnected' && !isConnecting) {
            setState(() {
              isConnected = false;
              statusMessage = 'Connection lost. Please try again.';
            });
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _connectionListener?.cancel();
    _pairingTimer?.cancel();
    super.dispose();
  }

  void _completePairing() {
    // Navigate to appropriate dashboard based on device type
    if (deviceType == 'parent') {
      // Navigate to parent dashboard
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/parentdashboard', // Replace with your actual parent dashboard route
            (route) => false, // Remove all previous routes
        arguments: {
          'connectionId': connectionId,
          'connectionData': connectionData,
          'deviceInfo': currentDeviceInfo,
        },
      );
    } else {
      // Navigate to child/player dashboard
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/playerdashboard', // Replace with your actual player dashboard route
            (route) => false, // Remove all previous routes
        arguments: {
          'connectionId': connectionId,
          'connectionData': connectionData,
          'deviceInfo': currentDeviceInfo,
        },
      );
    }
  }

  String _getParentDeviceName() {
    Map<String, dynamic>? parentInfo;

    // Get parent device info based on device type
    if (deviceType == 'parent') {
      // If this is the parent device, use current device info
      parentInfo = currentDeviceInfo;
    } else {
      // If this is the child device, get parent info from connection data
      parentInfo = connectionData['parentDeviceInfo'] as Map<String, dynamic>?;
    }

    if (parentInfo != null) {
      // Try deviceName first
      if (parentInfo['deviceName'] != null && parentInfo['deviceName']!.toString().isNotEmpty) {
        return parentInfo['deviceName'].toString();
      }

      // Try model
      if (parentInfo['model'] != null && parentInfo['model']!.toString().isNotEmpty) {
        return parentInfo['model'].toString();
      }

      // Try manufacturer + model combination
      final manufacturer = parentInfo['manufacturer']?.toString() ?? '';
      final model = parentInfo['model']?.toString() ?? '';
      final combined = '$manufacturer $model'.trim();
      if (combined.isNotEmpty) {
        return combined;
      }

      // Try name (for iOS devices)
      if (parentInfo['name'] != null && parentInfo['name']!.toString().isNotEmpty) {
        return parentInfo['name'].toString();
      }
    }

    return deviceType == 'parent' ? 'This Device (Parent)' : 'Parent Device';
  }

  String _getParentDeviceType() {
    Map<String, dynamic>? parentInfo;

    // Get parent device info based on device type
    if (deviceType == 'parent') {
      parentInfo = currentDeviceInfo;
    } else {
      parentInfo = connectionData['parentDeviceInfo'] as Map<String, dynamic>?;
    }

    if (parentInfo != null && parentInfo['platform'] != null) {
      return '${parentInfo['platform']} Device';
    }

    return deviceType == 'parent' ? 'This Device (Parent)' : 'Parent Device';
  }

  String _getChildDeviceName() {
    Map<String, dynamic>? childInfo;

    // Get child device info based on device type
    if (deviceType == 'child') {
      // If this is the child device, use current device info
      childInfo = currentDeviceInfo;
    } else {
      // If this is the parent device, get child info from connection data
      childInfo = connectionData['childDeviceInfo'] as Map<String, dynamic>?;
    }

    if (childInfo != null) {
      // Try deviceName first
      if (childInfo['deviceName'] != null && childInfo['deviceName']!.toString().isNotEmpty) {
        return childInfo['deviceName'].toString();
      }

      // Try model
      if (childInfo['model'] != null && childInfo['model']!.toString().isNotEmpty) {
        return childInfo['model'].toString();
      }

      // Try manufacturer + model combination
      final manufacturer = childInfo['manufacturer']?.toString() ?? '';
      final model = childInfo['model']?.toString() ?? '';
      final combined = '$manufacturer $model'.trim();
      if (combined.isNotEmpty) {
        return combined;
      }

      // Try name (for iOS devices)
      if (childInfo['name'] != null && childInfo['name']!.toString().isNotEmpty) {
        return childInfo['name'].toString();
      }
    }

    return deviceType == 'child' ? 'This Device (You)' : 'Player Device';
  }

  String _getChildDeviceType() {
    Map<String, dynamic>? childInfo;

    // Get child device info based on device type
    if (deviceType == 'child') {
      childInfo = currentDeviceInfo;
    } else {
      childInfo = connectionData['childDeviceInfo'] as Map<String, dynamic>?;
    }

    if (childInfo != null && childInfo['platform'] != null) {
      return '${childInfo['platform']} Device';
    }

    return deviceType == 'child' ? 'This Device (Child)' : 'Child Device';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1D29),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1D29),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: isConnecting ? null : () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Device Pairing',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Parent Device Info Section
            _buildParentDeviceSection(),

            const SizedBox(height: 20),

            // Connection Arrow
            _buildConnectionIndicator(),

            const SizedBox(height: 20),

            // Child Device Info Section (This Device)
            _buildChildDeviceSection(),

            const SizedBox(height: 30),

            // Connection Status Section
            _buildConnectionStatusSection(),

            const SizedBox(height: 30),

            // Action Button Section
            _buildActionSection(),

            const SizedBox(height: 20),

            // Device Code Section
            _buildDeviceCodeSection(),

          ],
        ),
      ),
    );
  }

  Widget _buildParentDeviceSection() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(isConnecting && _pairingProgress >= 1 ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Colors.blue.withOpacity(isConnecting && _pairingProgress >= 1 ? 0.5 : 0.3),
          width: isConnecting && _pairingProgress >= 1 ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.smartphone,
                color: Colors.blue,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                deviceType == 'parent' ? 'This Device (Parent)' : 'Parent Device',
                style: TextStyle(
                  color: Colors.blue,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (isConnecting && _pairingProgress >= 1) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.2),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(
              _getParentDeviceIcon(),
              size: 30,
              color: Colors.blue,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _getParentDeviceName(),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            _getParentDeviceType(),
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withOpacity(0.7),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionIndicator() {
    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          child: Icon(
            isConnected ? Icons.check_circle :
            isConnecting ? Icons.sync : Icons.link,
            color: isConnected ? Colors.green : const Color(0xFFE8956C),
            size: 30,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: 2,
          height: 20,
          color: isConnected ? Colors.green.withOpacity(0.5) : Colors.white.withOpacity(0.3),
        ),
      ],
    );
  }

  Widget _buildChildDeviceSection() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFE8956C).withOpacity(isConnecting && _pairingProgress >= 3 ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: const Color(0xFFE8956C).withOpacity(isConnecting && _pairingProgress >= 3 ? 0.5 : 0.3),
          width: isConnecting && _pairingProgress >= 3 ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.smartphone,
                color: const Color(0xFFE8956C),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                deviceType == 'child' ? 'This Device (You)' : 'Player Device',
                style: TextStyle(
                  color: const Color(0xFFE8956C),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (isConnecting && _pairingProgress >= 3) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: const Color(0xFFE8956C).withOpacity(0.2),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(
              _getChildDeviceIcon(),
              size: 30,
              color: const Color(0xFFE8956C),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _getChildDeviceName(),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            _getChildDeviceType(),
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withOpacity(0.7),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatusSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
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
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: isConnecting ? _pulseAnimation.value : 1.0,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: _getStatusColor().withOpacity(0.2),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Icon(
                    _getStatusIcon(),
                    size: 30,
                    color: _getStatusColor(),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            _getStatusTitle(),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            _getStatusDescription(),
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withOpacity(0.7),
            ),
            textAlign: TextAlign.center,
          ),
          if (isConnecting) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: (_pairingProgress + 1) / _pairingSteps.length,
              backgroundColor: Colors.white.withOpacity(0.2),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
            ),
            const SizedBox(height: 8),
            Text(
              'Step ${_pairingProgress + 1} of ${_pairingSteps.length}',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionSection() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _getButtonAction(),
        style: ElevatedButton.styleFrom(
          backgroundColor: _getButtonColor(),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isConnecting) ...[
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Icon(
              _getButtonIcon(),
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              _getButtonText(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCodeSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Colors.white.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.code,
                color: Colors.white.withOpacity(0.7),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Connection Code',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.7),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Colors.white.withOpacity(0.1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    connectionId.isEmpty ? 'No code available' : connectionId,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                if (connectionId.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: connectionId));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Connection code copied to clipboard'),
                          backgroundColor: Color(0xFFE8956C),
                        ),
                      );
                    },
                    child: Icon(
                      Icons.copy,
                      color: Colors.white.withOpacity(0.7),
                      size: 16,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _getParentDeviceIcon() {
    Map<String, dynamic>? parentInfo;

    if (deviceType == 'parent') {
      parentInfo = currentDeviceInfo;
    } else {
      parentInfo = connectionData['parentDeviceInfo'] as Map<String, dynamic>?;
    }

    if (parentInfo != null) {
      final platform = parentInfo['platform']?.toString().toLowerCase();
      if (platform?.contains('android') == true) {
        return Icons.android;
      } else if (platform?.contains('ios') == true) {
        return Icons.phone_iphone;
      }
    }

    return Icons.smartphone;
  }

  IconData _getChildDeviceIcon() {
    Map<String, dynamic>? childInfo;

    if (deviceType == 'child') {
      childInfo = currentDeviceInfo;
    } else {
      childInfo = connectionData['childDeviceInfo'] as Map<String, dynamic>?;
    }

    if (childInfo != null) {
      final platform = childInfo['platform']?.toString().toLowerCase();
      if (platform?.contains('android') == true) {
        return Icons.android;
      } else if (platform?.contains('ios') == true) {
        return Icons.phone_iphone;
      }
    }

    return Icons.tablet_android; // Default for child device
  }

  Color _getStatusColor() {
    if (isConnected) return Colors.green;
    if (isConnecting) return const Color(0xFFE8956C);
    return Colors.white.withOpacity(0.7);
  }

  IconData _getStatusIcon() {
    if (isConnected) return Icons.check_circle;
    if (isConnecting) return Icons.sync;
    return Icons.wifi_off;
  }

  String _getStatusTitle() {
    if (isConnected) return 'Connected Successfully!';
    if (isConnecting) return 'Pairing Devices...';
    return 'Ready to Connect';
  }

  String _getStatusDescription() {
    if (statusMessage.isNotEmpty) return statusMessage;
    if (isConnected) return 'Your devices have been successfully paired and are ready to use.';
    if (isConnecting) return 'Please wait while we establish a secure connection between devices...';
    return 'Connection established. Finalizing pairing process...';
  }

  Color _getButtonColor() {
    if (isConnected) return Colors.green;
    if (isConnecting) return Colors.grey;
    return const Color(0xFFE8956C);
  }

  IconData _getButtonIcon() {
    if (isConnected) return Icons.done;
    if (isConnecting) return Icons.sync;
    return Icons.link;
  }

  String _getButtonText() {
    if (isConnected) return 'Complete Setup';
    if (isConnecting) return 'Pairing in Progress...';
    return 'Finalizing Connection';
  }

  VoidCallback? _getButtonAction() {
    if (isConnecting) return null;
    if (isConnected) return _completePairing;
    return null; // Auto-connecting based on Firestore data
  }
}