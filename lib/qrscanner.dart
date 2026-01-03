import 'package:flutter/material.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';

class QRScannerScreen extends StatefulWidget {
  final Map<String, dynamic> deviceInfo;

  const QRScannerScreen({
    Key? key,
    required this.deviceInfo,
  }) : super(key: key);

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  final TextEditingController _manualController = TextEditingController();
  QRViewController? controller;
  bool isScanning = true;
  bool flashOn = false;
  bool isConnecting = false;
  StreamSubscription<DocumentSnapshot>? _connectionListener;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  void dispose() {
    controller?.dispose();
    _manualController.dispose();
    _connectionListener?.cancel();
    super.dispose();
  }

  void _onQRViewCreated(QRViewController controller) {
    this.controller = controller;
    controller.scannedDataStream.listen((scanData) {
      if (isScanning && !isConnecting) {
        setState(() {
          isScanning = false;
        });
        _handleScannedData(scanData.code ?? '');
      }
    });
  }

  void _handleScannedData(String data) {
    // Vibrate on successful scan
    HapticFeedback.vibrate();

    // Check if the code starts with ICTRL prefix
    if (data.startsWith('ICTRL')) {
      _attemptConnection(data);
    } else {
      // Show error dialog for invalid QR code
      _showErrorDialog('Invalid QR Code', 'This QR code is not compatible with this app. Please scan a valid device QR code.');
    }
  }

  void _handleManualSubmit() {
    String manualCode = _manualController.text.trim();
    if (manualCode.isEmpty) {
      _showErrorDialog('Empty Code', 'Please enter a device code.');
      return;
    }

    if (manualCode.startsWith('ICTRL')) {
      _attemptConnection(manualCode);
    } else {
      _showErrorDialog('Invalid Code', 'The entered code is not valid. Please make sure it starts with ICTRL.');
    }
  }

  Future<void> _attemptConnection(String connectionId) async {
    setState(() {
      isConnecting = true;
    });

    try {
      print('Attempting to connect to: $connectionId');
      print('Device Info: ${widget.deviceInfo}');

      // Check if the paired_devices document exists
      final docRef = _firestore.collection('paired_devices').doc(connectionId);
      final docSnapshot = await docRef.get();

      if (!docSnapshot.exists) {
        print('Document does not exist');
        _showErrorDialog('Connection Not Found', 'The device with this code is not available or has expired.');
        setState(() {
          isConnecting = false;
          isScanning = true;
        });
        return;
      }

      final data = docSnapshot.data() as Map<String, dynamic>;
      print('Document data: $data');

      // Check if the connection is still waiting for a child device
      if (data['status'] != 'waiting_for_child') {
        print('Connection status is not waiting_for_child: ${data['status']}');
        _showErrorDialog('Connection Unavailable', 'This device is no longer available for pairing.');
        setState(() {
          isConnecting = false;
          isScanning = true;
        });
        return;
      }

      // Check if childDeviceId is already set (already paired)
      if (data['childDeviceId'] != null) {
        print('Child device already connected');
        _showErrorDialog('Already Paired', 'This device is already paired with another device.');
        setState(() {
          isConnecting = false;
          isScanning = true;
        });
        return;
      }

      print('Updating document with child device info');

      // Create child device identifier using device info
      String childDeviceId;
      if (widget.deviceInfo['androidId'] != null) {
        childDeviceId = 'child_android_${widget.deviceInfo['androidId']}';
      } else if (widget.deviceInfo['identifierForVendor'] != null) {
        childDeviceId = 'child_ios_${widget.deviceInfo['identifierForVendor']}';
      } else {
        childDeviceId = 'child_${DateTime.now().millisecondsSinceEpoch}';
      }

      // Update the document to indicate child device has connected
      await docRef.update({
        'childDeviceId': childDeviceId,
        'childDeviceInfo': widget.deviceInfo,
        'status': 'connected',
        'connectedAt': FieldValue.serverTimestamp(),
      });

      print('Document updated successfully');

      // Wait a moment for the update to propagate
      await Future.delayed(const Duration(milliseconds: 500));

      // Get the updated document data
      final updatedDoc = await docRef.get();
      if (!updatedDoc.exists) {
        throw Exception('Document was deleted after update');
      }

      final updatedData = updatedDoc.data() as Map<String, dynamic>;
      print('Updated document data: $updatedData');

      // Navigate to paired device screen
      if (mounted) {
        Navigator.pushReplacementNamed(
            context,
            '/paireddevice',
            arguments: {
              'connectionId': connectionId,
              'deviceType': 'child',
              'data': updatedData,
              'deviceInfo': widget.deviceInfo,
            }
        );
      }

    } catch (e) {
      print('Error connecting to device: $e');
      _showErrorDialog('Connection Error', 'Failed to connect to the device. Please try again.\n\nError: $e');
      setState(() {
        isConnecting = false;
        isScanning = true;
      });
    }
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
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
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
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                isScanning = true;
                isConnecting = false;
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE8956C),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Try Again',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleFlash() {
    controller?.toggleFlash();
    setState(() {
      flashOn = !flashOn;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1D29),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1D29),
        elevation: 0,
        title: const Text(
          'Add Device',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              flashOn ? Icons.flash_on : Icons.flash_off,
              color: flashOn ? const Color(0xFFE8956C) : Colors.white,
            ),
            onPressed: _toggleFlash,
          ),
        ],
      ),
      // Use SingleChildScrollView to handle keyboard overflow
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height -
                  AppBar().preferredSize.height -
                  MediaQuery.of(context).padding.top,
            ),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  // Connection Status - Fixed height to prevent layout shifts
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    height: isConnecting ? 80 : 0,
                    child: isConnecting
                        ? Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      margin: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8956C).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: const Color(0xFFE8956C).withOpacity(0.3),
                          width: 1,
                        ),
                      ),
                      child: const Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Color(0xFFE8956C),
                              strokeWidth: 2,
                            ),
                          ),
                          SizedBox(width: 15),
                          Text(
                            'Connecting to device...',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    )
                        : const SizedBox.shrink(),
                  ),

                  // QR Scanner Section - Flexible height
                  Expanded(
                    flex: 3,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      constraints: const BoxConstraints(
                        minHeight: 280,
                        maxHeight: 400,
                      ),
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
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.qr_code_scanner,
                                  color: Color(0xFFE8956C),
                                  size: 24,
                                ),
                                SizedBox(width: 12),
                                Text(
                                  'Scan QR Code',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Container(
                              margin: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.2),
                                  width: 2,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: QRView(
                                  key: qrKey,
                                  onQRViewCreated: _onQRViewCreated,
                                  overlay: QrScannerOverlayShape(
                                    borderColor: const Color(0xFFE8956C),
                                    borderRadius: 20,
                                    borderLength: 40,
                                    borderWidth: 6,
                                    cutOutSize: MediaQuery.of(context).size.width * 0.6,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              isConnecting
                                  ? 'Connecting to device...'
                                  : 'Position the QR code within the frame',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.white.withOpacity(0.7),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Manual Input Section - Fixed minimum height
                  Container(
                    margin: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                    constraints: const BoxConstraints(
                      minHeight: 200,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.2),
                        width: 1,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.keyboard,
                                color: Color(0xFFE8956C),
                                size: 24,
                              ),
                              SizedBox(width: 12),
                              Text(
                                'Enter Code Manually',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'Device Code',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.8),
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.2),
                                width: 1,
                              ),
                            ),
                            child: TextField(
                              controller: _manualController,
                              enabled: !isConnecting,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Enter device code (e.g., ICTRL...)',
                                hintStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.5),
                                  fontSize: 14,
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                              onSubmitted: (_) => _handleManualSubmit(),
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: isConnecting ? null : _handleManualSubmit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFE8956C),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 16),
                              ),
                              child: isConnecting
                                  ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                                  : const Text(
                                'Add Device',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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