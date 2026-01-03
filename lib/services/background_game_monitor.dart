import 'dart:async';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'monitoring_preferences.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:installed_apps/app_info.dart';

class EnhancedBackgroundGameMonitor {
  static const String ENHANCED_MONITOR_TASK = "enhancedGameMonitorTask";

  // Method channels for native communication
  static const MethodChannel _backgroundChannel =
  MethodChannel('com.ictrl.ictrl/enhanced_background_monitor');
  static const MethodChannel _appMonitorChannel =
  MethodChannel('com.ictrl.ictrl/app_monitor');

  static Timer? _monitoringTimer;
  static Timer? _connectionIdRefreshTimer;
  static Set<String> _monitoredGames = {};
  static Set<String> _allowedGames = {}; // Currently allowed games
  static String? _connectionId;
  static String? _currentDeviceId;
  static bool _isMonitoring = false;
  static bool _isInitialized = false;
  static Map<String, bool> _gamePermissions = {}; // Cache game permissions
  static StreamSubscription<DocumentSnapshot>? _allowedGamesSub;

  static Timer? _backgroundSessionUpdateTimer;
  static String? _backgroundActiveGamePackage;
  static final Map<String, String> _activeSessionIdsByPackage = {};
  static final Map<String, Timer> _heartbeatTimersByPackage = {};
  static const Duration _freshnessWindow = Duration(seconds: 90);

  // Initialize enhanced monitoring
  static Future<void> initialize() async {
    if (_isInitialized) return;

    print('🎮 🛡️ Initializing Enhanced Background Game Monitor');

    try {
      // Initialize device info first
      await _initializeDeviceInfo();

      // Fetch connectionId from paired devices
      await _fetchAndSetConnectionId();

      // Request all necessary permissions
      await _requestAllPermissions();

      // Initialize Workmanager
      await Workmanager().initialize(
        enhancedCallbackDispatcher,
        isInDebugMode: true,
      );

      // Set up method call handler for native communication
      _backgroundChannel.setMethodCallHandler(_handleNativeCall);

      _isInitialized = true;
      print('🎮 🛡️ Enhanced Background Game Monitor initialized successfully');
      debugConnectionId();
    } catch (e) {
      print('🎮 ❌ Error initializing Enhanced Background Game Monitor: $e');
      throw e;
    }
    if (_connectionId != null) {
      FirebaseFirestore.instance
          .collection('allowed_games')
          .doc(_connectionId!)
          .snapshots()
          .listen((doc) async {
        print('🎮 [DEBUG] allowed_games changed, forcing immediate permission update.');
        await _loadGamePermissions();
        await _backgroundChannel.invokeMethod('forceImmediateCheck');
      });

      FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .snapshots()
          .listen((doc) async {
        print('🎮 [DEBUG] gaming_scheduled changed, forcing immediate permission update.');
        await _loadGamePermissions();
        await _backgroundChannel.invokeMethod('forceImmediateCheck');
      });
    }
  }

  // Initialize device info
  static Future<void> _initializeDeviceInfo() async {
    try {
      DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;

      // Use available identifiers in order of preference
      _currentDeviceId = androidInfo.id ??
          androidInfo.fingerprint ??
          androidInfo.serialNumber ??
          androidInfo.model ??
          'unknown_device';

      print('🎮 🛡️ Device ID initialized: $_currentDeviceId');
      print('🎮 🛡️ Device info - Model: ${androidInfo.model}, Brand: ${androidInfo.brand}');
    } catch (e) {
      print('🎮 ❌ Error initializing device info: $e');
      _currentDeviceId = 'unknown_device';
    }
  }

  // Fetch connectionId from paired_devices collection (similar to playerdashboard.dart)
  static Future<void> _fetchAndSetConnectionId() async {
    try {
      print('🎮 🛡️ Starting to fetch connectionId from paired_devices...');

      if (_currentDeviceId == null || _currentDeviceId!.isEmpty) {
        print('🎮 ❌ Device ID not available, cannot fetch connectionId');
        return;
      }

      // Create the child device ID with the proper prefix
      final childDeviceId = 'child_android_$_currentDeviceId';
      print('🎮 🛡️ Looking for childDeviceId: $childDeviceId');

      // Query paired_devices collection to find document where current device is paired
      final QuerySnapshot pairedDevicesSnapshot = await FirebaseFirestore.instance
          .collection('paired_devices')
          .where('childDeviceId', isEqualTo: childDeviceId)
          .get();

      print('🎮 🛡️ Found ${pairedDevicesSnapshot.docs.length} paired device records');

      if (pairedDevicesSnapshot.docs.isNotEmpty) {
        // Get the first matching document (should only be one)
        final DocumentSnapshot doc = pairedDevicesSnapshot.docs.first;
        final data = doc.data() as Map<String, dynamic>?;

        if (data != null) {
          // The connectionId is the document ID itself
          _connectionId = doc.id;
          print('🎮 ✅ Found and set connectionId: $_connectionId');
          print('🎮 🛡️ Paired device data: $data');

          // Save to preferences for background tasks
          await _saveConnectionIdToPreferences();

          return;
        }
      }

      // If we get here, no paired device was found
      print('🎮 ❌ No paired device found for childDeviceId: $childDeviceId');
      await _debugPairedDevices();

    } catch (e, stackTrace) {
      print('🎮 ❌ Error fetching connectionId from paired_devices: $e');
      print('🎮 Stack trace: $stackTrace');
    }
  }

  // Debug method to see all paired devices
  static Future<void> _debugPairedDevices() async {
    try {
      print('🎮 🔍 DEBUG: Checking all paired devices...');
      final QuerySnapshot allPairedDevices = await FirebaseFirestore.instance
          .collection('paired_devices')
          .get();

      print('🎮 🔍 Total paired devices in collection: ${allPairedDevices.docs.length}');

      for (var doc in allPairedDevices.docs) {
        final data = doc.data() as Map<String, dynamic>?;
        print('🎮 🔍 - Document ID: ${doc.id}');
        print('🎮 🔍 - Data: $data');
        if (data != null) {
          print('🎮 🔍 - childDeviceId: ${data['childDeviceId']}');
          print('🎮 🔍 - parentDeviceId: ${data['parentDeviceId']}');
        }
      }
    } catch (e) {
      print('🎮 ❌ Error debugging paired devices: $e');
    }
  }

  // Save connectionId to preferences for background tasks
  static Future<void> _saveConnectionIdToPreferences() async {
    try {
      if (_connectionId != null) {
        await MonitoringPreferences.saveConnectionId(_connectionId!);
        print('🎮 🛡️ Saved connectionId to preferences: $_connectionId');
      }
    } catch (e) {
      print('🎮 ❌ Error saving connectionId to preferences: $e');
    }
  }

  // Load connectionId from preferences (for background tasks)
  static Future<void> _loadConnectionIdFromPreferences() async {
    try {
      _connectionId = await MonitoringPreferences.getConnectionId();
      if (_connectionId != null) {
        print('🎮 🛡️ Loaded connectionId from preferences: $_connectionId');
      } else {
        print('🎮 ❌ No connectionId found in preferences');
      }
    } catch (e) {
      print('🎮 ❌ Error loading connectionId from preferences: $e');
    }
  }

  static Future<void> startAllowedGamesSync(String connectionId) async {
    try {
      _allowedGamesSub?.cancel();

      final docRef = FirebaseFirestore.instance.collection('allowed_games').doc(connectionId);

      _allowedGamesSub = docRef.snapshots().listen((snapshot) async {
        try {
          if (!snapshot.exists || snapshot.data() == null) {
            print('[ENHANCED_MONITOR] allowed_games doc missing or empty for $connectionId');
            // still notify native with empty allowed list (so native unblocks if needed)
            await _sendPermissionsToNative(connectionId, [], []);
            return;
          }

          final data = snapshot.data() as Map<String, dynamic>;
          final List<dynamic> allowedGames = data['allowedGames'] ?? [];

          // Build set of package names from allowed_games entries.
          // Prefer explicit packageName field.
          final Set<String> allowedPackages = <String>{};
          for (final entry in allowedGames) {
            if (entry is Map) {
              final pkg = (entry['packageName'] ?? '').toString().trim();
              final isAllowed = entry['isGameAllowed'] == true;
              if (isAllowed && pkg.isNotEmpty) allowedPackages.add(pkg);
            }
          }

          // For monitoring we also want the monitored list — try to get monitored package list
          // If you store monitored packages elsewhere (e.g. installed_games or another doc),
          // adapt the code below. As an example we'll try to read installed_games/<connectionId>.
          final monitoredPackages = await _fetchMonitoredPackages(connectionId);

          print('[ENHANCED_MONITOR] Syncing to native. monitored=${monitoredPackages.length}, allowed=${allowedPackages.length}');
          print('[ENHANCED_MONITOR] allowedPackages: $allowedPackages');

          await _sendPermissionsToNative(connectionId, monitoredPackages, allowedPackages.toList());
        } catch (e, st) {
          print('[ENHANCED_MONITOR] Error while processing allowed_games snapshot: $e\n$st');
        }
      },
          onError: (err) {
            print('[ENHANCED_MONITOR] allowed_games stream error: $err');
          });

    } catch (e, st) {
      print('[ENHANCED_MONITOR] startAllowedGamesSync error: $e\n$st');
    }
  }

  static Future<void> stopAllowedGamesSync() async {
    await _allowedGamesSub?.cancel();
    _allowedGamesSub = null;
  }

  static Future<void> _sendPermissionsToNative(
      String connectionId, List<String> monitoredPackages, List<String> allowedPackages) async {
    try {
      final payload = {
        'connectionId': connectionId,
        'monitoredGames': monitoredPackages,
        'allowedGames': allowedPackages,
      };

      print('[ENHANCED_MONITOR] Invoking native updateGamePermissions with payload: monitored=${monitoredPackages.length} allowed=${allowedPackages.length}');
      await _backgroundChannel.invokeMethod('updateGamePermissions', payload);
      print('[ENHANCED_MONITOR] Native updateGamePermissions invoked');
    } on PlatformException catch (e) {
      print('[ENHANCED_MONITOR] PlatformException sending permissions to native: ${e.message}');
    } catch (e, st) {
      print('[ENHANCED_MONITOR] Unknown error sending permissions to native: $e\n$st');
    }
  }

  static Future<List<String>> _fetchMonitoredPackages(String connectionId) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('installed_games').doc(connectionId).get();
      if (!doc.exists || doc.data() == null) return [];
      final data = doc.data() as Map<String, dynamic>;
      final games = data['games'] as List<dynamic>? ?? [];
      final List<String> pkgs = [];
      for (final g in games) {
        if (g is Map && (g['packageName'] ?? '').toString().trim().isNotEmpty) {
          pkgs.add(g['packageName'].toString().trim());
        }
      }
      return pkgs;
    } catch (e) {
      print('[ENHANCED_MONITOR] _fetchMonitoredPackages error: $e');
      return [];
    }
  }

  static void debugConnectionId() {
    print('🔍 === CONNECTION ID DEBUG ===');
    print('🔍 _connectionId value: "$_connectionId"');
    print('🔍 _connectionId is null: ${_connectionId == null}');
    print('🔍 _connectionId is empty: ${_connectionId?.isEmpty ?? "null"}');
    print('🔍 _currentDeviceId: "$_currentDeviceId"');
    print('🔍 _isInitialized: $_isInitialized');
    print('🔍 _isMonitoring: $_isMonitoring');
    print('🔍 _monitoredGames count: ${_monitoredGames.length}');
    print('🔍 _allowedGames count: ${_allowedGames.length}');
    print('🔍 === END DEBUG ===');
  }

  static void debugTaskName() {
    print('🔍 ENHANCED_MONITOR_TASK constant:');
    print('  - Value: "$ENHANCED_MONITOR_TASK"');
    print('  - Length: ${ENHANCED_MONITOR_TASK.length}');
    print('  - Bytes: ${ENHANCED_MONITOR_TASK.codeUnits}');
  }

  // Request all necessary permissions
  static Future<void> _requestAllPermissions() async {
    try {
      print('🎮 🛡️ Requesting enhanced permissions...');

      // 1. Usage Stats permission
      bool hasUsageStats = await _appMonitorChannel.invokeMethod('hasUsageStatsPermission');
      if (!hasUsageStats) {
        print('🎮 🛡️ Requesting Usage Stats permission...');
        await _appMonitorChannel.invokeMethod('requestUsageStatsPermission');
        await Future.delayed(Duration(seconds: 2));
        hasUsageStats = await _appMonitorChannel.invokeMethod('hasUsageStatsPermission');
      }

      // 2. System Alert Window permission (for overlay blocking)
      bool hasOverlay = await _appMonitorChannel.invokeMethod('hasOverlayPermission');
      if (!hasOverlay) {
        print('🎮 🛡️ Requesting Overlay permission...');
        await _appMonitorChannel.invokeMethod('requestOverlayPermission');
      }

      // 3. Notification permission
      final notificationStatus = await Permission.notification.status;
      if (!notificationStatus.isGranted) {
        await Permission.notification.request();
      }

      // 4. Device Admin permission (optional, for stronger blocking)
      await _requestDeviceAdminPermission();

      print('🎮 🛡️ Permissions status - Usage: $hasUsageStats, Overlay: $hasOverlay, Notification: ${notificationStatus.isGranted}');
    } catch (e) {
      print('🎮 ❌ Error requesting enhanced permissions: $e');
    }
  }

  // Request device admin permission for stronger blocking
  static Future<void> _requestDeviceAdminPermission() async {
    try {
      bool isDeviceAdmin = await _appMonitorChannel.invokeMethod('isDeviceAdmin');
      if (!isDeviceAdmin) {
        print('🎮 🛡️ Device admin not enabled - requesting...');
        await _appMonitorChannel.invokeMethod('requestDeviceAdmin');
      }
    } catch (e) {
      print('🎮 ❌ Error with device admin: $e');
    }
  }

  // Handle calls from native Android code
  static Future<dynamic> _handleNativeCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'gameDetected':
          String packageName = call.arguments['packageName'] as String;
          bool isBlocked = call.arguments['isBlocked'] as bool;
          print('🎮 🛡️ ENHANCED DETECTION: $packageName (blocked: $isBlocked)');
          await _handleEnhancedGameDetection(packageName, isBlocked);
          break;
        case 'blockingStatusChanged':
          bool isBlocking = call.arguments['isBlocking'] as bool;
          String? packageName = call.arguments['packageName'] as String?;
          print('🎮 🛡️ Blocking status changed: $isBlocking for $packageName');
          break;
        case 'log':
          String message = call.arguments as String;
          print('🎮 🛡️ [NATIVE]: $message');
          break;
        default:
          print('🎮 🛡️ Unknown enhanced native call: ${call.method}');
      }
    } catch (e) {
      print('🎮 ❌ Error handling enhanced native call: $e');
    }
  }

  // Start enhanced monitoring
  static Future<void> startEnhancedMonitoring(String? providedConnectionId) async {
    print('🔍 === STARTING ENHANCED MONITORING ===');
    print('🔍 Provided connectionId: "$providedConnectionId"');

    if (!_isInitialized) {
      await initialize();
    }

    // If connectionId is provided, use it; otherwise fetch from paired devices
    if (providedConnectionId != null && providedConnectionId.isNotEmpty) {
      _connectionId = providedConnectionId;
      await _saveConnectionIdToPreferences();
      print('🔍 Using provided connectionId: "$_connectionId"');
    } else if (_connectionId == null) {
      // Try to fetch from paired devices if not already set
      await _fetchAndSetConnectionId();
      if (_connectionId == null) {
        // Last resort: try to load from preferences
        await _loadConnectionIdFromPreferences();
      }
    }

    if (_connectionId == null || _connectionId!.isEmpty) {
      print('🎮 ❌ Cannot start monitoring: No valid connectionId available');
      throw Exception('No valid connectionId available for monitoring');
    }

    _isMonitoring = true;

    print('🎮 🛡️ Starting enhanced background monitoring for connection: $_connectionId');

    try {
      // Load monitored games and permissions from Firestore
      await _loadGamePermissions();

      // Debug after loading permissions
      debugConnectionId();

      // Save monitoring preferences
      await MonitoringPreferences.saveMonitoringState(
        autoStart: true,
        connectionId: _connectionId!,
        monitoredGames: _monitoredGames.toList(),
      );

      // Start enhanced native service
      await _startEnhancedNativeService();

      // Register enhanced background task with debug
      print('🔍 Registering background task with connectionId: "$_connectionId"');
      await Workmanager().registerPeriodicTask(
        ENHANCED_MONITOR_TASK,
        ENHANCED_MONITOR_TASK,
        frequency: Duration(minutes: 10),
        initialDelay: Duration(seconds: 5),
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
        inputData: {
          'connectionId': _connectionId!, // Make sure this is not null
          'currentDeviceId': _currentDeviceId,
          'monitoredGames': _monitoredGames.toList(),
          'allowedGames': _allowedGames.toList(),
        },
      );

      // Start real-time permission monitoring
      _startPermissionMonitoring();

      // Start periodic connectionId refresh
      _startConnectionIdRefresh();

      // Final debug check
      debugConnectionId();

      print('🎮 🛡️ Enhanced monitoring started successfully');
    } catch (e) {
      print('🎮 ❌ Error starting enhanced monitoring: $e');
      debugConnectionId(); // Debug on error too
      throw e;
    }
  }

  // Start periodic connectionId refresh to ensure it stays current
  static void _startConnectionIdRefresh() {
    _connectionIdRefreshTimer?.cancel();

    _connectionIdRefreshTimer = Timer.periodic(Duration(minutes: 5), (timer) async {
      if (!_isMonitoring) {
        timer.cancel();
        return;
      }

      try {
        String? oldConnectionId = _connectionId;
        await _fetchAndSetConnectionId();

        if (_connectionId != oldConnectionId) {
          print('🎮 🛡️ ConnectionId changed from $oldConnectionId to $_connectionId');
          // Update native service and background tasks if needed
          await _updateNativeGamePermissions();
        }
      } catch (e) {
        print('🎮 ❌ Error refreshing connectionId: $e');
      }
    });

    print('🎮 🛡️ ConnectionId refresh timer started (5-minute intervals)');
  }

  // Load game permissions and determine allowed games
  static Future<void> _loadGamePermissions() async {
    try {
      if (_connectionId == null) {
        print('🎮 ❌ Cannot load game permissions: connectionId is null');
        return;
      }

      print('🎮 🛡️ Loading game permissions for connection: $_connectionId');

      DocumentSnapshot allowedDoc = await FirebaseFirestore.instance
          .collection('allowed_games')
          .doc(_connectionId!)
          .get();

      DocumentSnapshot scheduleDoc = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .get();

      _monitoredGames.clear();
      _allowedGames.clear();
      _gamePermissions.clear();

      if (allowedDoc.exists) {
        Map<String, dynamic> allowedData = allowedDoc.data() as Map<String, dynamic>;
        List<dynamic> allowedGamesList = allowedData['allowedGames'] ?? [];

        for (var game in allowedGamesList) {
          String packageName = game['packageName'] ?? '';
          bool isGameAllowed = game['isGameAllowed'] ?? false;
          String gameName = game['name'] ?? game['gameName'] ?? packageName;

          bool unlockByKey = game['unlockByKey'] == true;
          Timestamp? unlockExpiryTs = game['unlockExpiry'] as Timestamp?;
          DateTime? unlockExpiryDate = unlockExpiryTs?.toDate();
          bool validUnlockKey = unlockByKey && unlockExpiryDate != null && DateTime.now().isBefore(unlockExpiryDate);

          if (packageName.isEmpty) continue;

          _monitoredGames.add(packageName);

          bool isCurrentlyAllowed;

          // NEW LOGIC: hierarchy of allowance
          if (validUnlockKey) {
            isCurrentlyAllowed = true; // Key always overrides
          } else if (isGameAllowed) {
            // Parent explicitly allowed the game -> ignore schedule gating
            isCurrentlyAllowed = true;
          } else {
            // Only rely on schedule gating if parent did NOT allow the game
            isCurrentlyAllowed = await _checkGameSchedule(gameName, scheduleDoc);
          }

          // Optional: log when schedule gating denies a game that parent did not allow
          if (!isCurrentlyAllowed && isGameAllowed) {
            // This condition should never occur now because isGameAllowed short-circuits above
            print('⚠ Unexpected gating: $packageName was isGameAllowed=true but ended up false.');
          } else if (!isCurrentlyAllowed && !isGameAllowed) {
            print('⛔ Schedule gating blocked: $packageName (parent not explicitly allowed)');
          }

          _gamePermissions[packageName] = isCurrentlyAllowed;
          if (isCurrentlyAllowed) _allowedGames.add(packageName);
        }
      }

      print('🎮 🛡️ Loaded permissions - Monitored: ${_monitoredGames.length}, Currently Allowed: ${_allowedGames.length}');
      print('🎮 🛡️ Allowed games (final set sent to native): $_allowedGames');

      await _updateNativeGamePermissions();

      // Remove duplicate forceImmediateCheck invocation (keep single)
      try {
        await _backgroundChannel.invokeMethod('forceImmediateCheck');
        print('🎮 🛡️ Forced native service to check running apps immediately');
      } catch (e) {
        print('🎮 ❌ Error forcing immediate check: $e');
      }

    } catch (e) {
      print('🎮 ❌ Error loading game permissions: $e');
    }
  }

// Replace in EnhancedBackgroundGameMonitor
  static Future<String?> _ensureGameSessionActive(String packageName, String gameName) async {
    try {
      if (_connectionId == null) return null;
      final sessions = FirebaseFirestore.instance
          .collection('game_sessions')
          .doc(_connectionId)
          .collection('sessions');

      // 1) If we already know the active sessionId for this package, validate it
      final cachedId = _activeSessionIdsByPackage[packageName];
      if (cachedId != null) {
        final cachedRef = sessions.doc(cachedId);
        final snap = await cachedRef.get();
        final data = snap.data();
        final bool isActive = data?['isActive'] == true;
        final Timestamp? hb = data?['heartbeat'] as Timestamp?;
        final bool fresh = hb != null && DateTime.now().difference(hb.toDate()) <= _freshnessWindow;
        if (snap.exists && isActive && fresh) {
          // Touch heartbeat so it stays fresh
          await cachedRef.update({
            'lastUpdateAt': FieldValue.serverTimestamp(),
            'heartbeat': FieldValue.serverTimestamp(),
          });
          return cachedId;
        } else {
          _activeSessionIdsByPackage.remove(packageName);
        }
      }

      // 2) Look for an existing active + fresh session for this package
      // NOTE: This query needs a composite index:
      // collection group sessions: packageName Asc, isActive Asc, launchedAt Desc
      final existingQ = await sessions
          .where('packageName', isEqualTo: packageName)
          .where('isActive', isEqualTo: true)
          .orderBy('launchedAt', descending: true)
          .limit(1)
          .get();

      if (existingQ.docs.isNotEmpty) {
        final doc = existingQ.docs.first;
        final data = doc.data();
        final Timestamp? hb = data['heartbeat'] as Timestamp?;
        final bool fresh = hb != null && DateTime.now().difference(hb.toDate()) <= _freshnessWindow;
        if (fresh) {
          // Reuse this existing active session
          await doc.reference.update({
            'lastUpdateAt': FieldValue.serverTimestamp(),
            'heartbeat': FieldValue.serverTimestamp(),
          });
          _activeSessionIdsByPackage[packageName] = doc.id;
          return doc.id;
        }
      }

      // 3) Create a new session (first detection of a new play session)
      final now = DateTime.now();
      final newRef = sessions.doc(); // unique per session occurrence
      await newRef.set({
        'sessionId': newRef.id,
        'connectionId': _connectionId,
        'childDeviceId': _currentDeviceId != null ? 'child_android_$_currentDeviceId' : 'child_android_enhanced',
        'gameName': gameName,
        'packageName': packageName,
        'launchedAt': now,
        'isActive': true,
        'lastUpdateAt': now,
        'heartbeat': now,
        'source': 'enhanced',
      });
      _activeSessionIdsByPackage[packageName] = newRef.id;
      return newRef.id;
    } catch (e) {
      print('Error ensuring game session active: $e');
      return null;
    }
  }

  // Check if game is allowed based on current schedule
  static Future<bool> _checkGameSchedule(String gameName, DocumentSnapshot? scheduleDoc) async {
    try {
      if (scheduleDoc == null || !scheduleDoc.exists) {
        // CHANGED: previously returned true or false depending on design. Adjust as needed.
        // To make schedules optional, return true here.
        return true;
      }
      final data = scheduleDoc.data() as Map<String, dynamic>?;
      if (data == null || data['schedules'] == null) return true;

      List<dynamic> schedules = data['schedules'];
      final now = DateTime.now();
      print('Checking schedule for $gameName at $now');

      for (var scheduleData in schedules) {
        if ((scheduleData['packageName'] == gameName || scheduleData['gameName'] == gameName) &&
            scheduleData['isActive'] == true) {
          String startTime = scheduleData['startTime'] ?? '';
          String endTime = scheduleData['endTime'] ?? '';
          if (startTime.isNotEmpty && endTime.isNotEmpty) {
            bool withinRange = _isWithinTimeRange(now, startTime, endTime);
            print('Within time range for $gameName: $withinRange');
            return withinRange;
          }
        }
      }
      print('No active schedule found for $gameName -> treating as NOT allowed under schedule gating');
      return false; // If schedules are mandatory for non-explicitly-allowed games
    } catch (e) {
      print('Error checking game schedule: $e');
      return true; // Fail-open to avoid accidental over-blocking
    }
  }

  // Check if current time is within allowed range
  static bool _isWithinTimeRange(DateTime now, String startTime, String endTime) {
    try {
      List<String> startParts = startTime.split(':');
      List<String> endParts = endTime.split(':');

      if (startParts.length != 2 || endParts.length != 2) return false;

      int startHour = int.parse(startParts[0]);
      int startMinute = int.parse(startParts[1]);
      int endHour = int.parse(endParts[0]);
      int endMinute = int.parse(endParts[1]);

      DateTime startDateTime = DateTime(now.year, now.month, now.day, startHour, startMinute);
      DateTime endDateTime = DateTime(now.year, now.month, now.day, endHour, endMinute);

      // Handle overnight schedules
      if (endDateTime.isBefore(startDateTime)) {
        endDateTime = endDateTime.add(Duration(days: 1));
      }

      return now.isAfter(startDateTime) && now.isBefore(endDateTime);
    } catch (e) {
      print('🎮 ❌ Error parsing time range: $e');
      return false;
    }
  }

  // Start enhanced native service
  static Future<void> _startEnhancedNativeService() async {
    try {
      print('🎮 🛡️ Starting enhanced native service');

      bool started = await _backgroundChannel.invokeMethod('startEnhancedService', {
        'monitoredGames': _monitoredGames.toList(),
        'allowedGames': _allowedGames.toList(),
        'connectionId': _connectionId,        // <-- Pass your connectionId here
        'childDeviceId': _currentDeviceId,
      });

      if (started) {
        print('🎮 🛡️ Enhanced native service started successfully');
      } else {
        print('🎮 ❌ Failed to start enhanced native service');
      }
    } catch (e) {
      print('🎮 ❌ Error starting enhanced native service: $e');
    }
  }

  static Future<void> _endActiveGameSession(String packageName) async {
    try {
      if (_connectionId == null) return;
      final sessions = FirebaseFirestore.instance
          .collection('game_sessions')
          .doc(_connectionId)
          .collection('sessions');

      final activeQ = await sessions
          .where('packageName', isEqualTo: packageName)
          .where('isActive', isEqualTo: true)
          .orderBy('launchedAt', descending: true)
          .limit(1)
          .get();

      if (activeQ.docs.isNotEmpty) {
        final ref = activeQ.docs.first.reference;
        final launchedAt = (activeQ.docs.first.data()['launchedAt'] as Timestamp).toDate();
        final endedAt = DateTime.now();
        final playTime = endedAt.difference(launchedAt).inSeconds;

        await ref.update({
          'isActive': false,
          'endedAt': endedAt,
          'totalPlayTimeSeconds': playTime,
          'lastUpdateAt': endedAt,
        });
      }
    } catch (e) {
      print('Error ending active game session: $e');
    } finally {
      // Clear timer and cache for this package
      _heartbeatTimersByPackage.remove(packageName)?.cancel();
      _activeSessionIdsByPackage.remove(packageName);
    }
  }

  // Update native service with current game permissions
  static Future<void> _updateNativeGamePermissions() async {
    try {
      await _backgroundChannel.invokeMethod('updateGamePermissions', {
        'monitoredGames': _monitoredGames.toList(),
        'allowedGames': _allowedGames.toList(),
      });
      print('🎮 🛡️ Updated native service with game permissions');
    } catch (e) {
      print('🎮 ❌ Error updating native game permissions: $e');
    }
  }

  // Start real-time permission monitoring
  static void _startPermissionMonitoring() {
    _monitoringTimer?.cancel();

    _monitoringTimer = Timer.periodic(Duration(seconds: 60), (timer) async {
      if (!_isMonitoring) {
        timer.cancel();
        return;
      }

      // Reload permissions every 30 seconds to catch schedule changes
      await _loadGamePermissions();
    });

    print('🎮 🛡️ Permission monitoring started (30-second intervals)');
  }

  // Handle enhanced game detection from native service
  static Future<void> _handleEnhancedGameDetection(String packageName, bool isBlocked) async {
    try {
      print('🎮 🛡️ === GAME DETECTION EVENT ===');
      print('🎮 🛡️ Package: $packageName');
      print('🎮 🛡️ Blocked: $isBlocked');

      // Ensure we have a valid connectionId before processing
      if (_connectionId == null || _connectionId!.isEmpty) {
        print('🎮 ❌ No connectionId available, attempting to fetch...');
        await _fetchAndSetConnectionId();

        if (_connectionId == null || _connectionId!.isEmpty) {
          print('🎮 ❌ Still no connectionId, cannot process detection');
          return;
        }
      }

      // Debug connectionId right at the start
      debugConnectionId();

      String gameName = await _getGameName(packageName);
      print('🎮 🛡️ Game Name: $gameName');

      if (isBlocked) {
        print('🎮 🛡️ 🚫 PROCESSING BLOCKED GAME: $gameName ($packageName)');

        // Step 1: Log violation with enhanced debugging
        print('🎮 🛡️ Step 1: Logging violation...');
        print('🔍 About to call _logEnhancedViolation with connectionId: "$_connectionId"');
        await _logEnhancedViolation(packageName, gameName);
        print('🎮 🛡️ Step 1: ✅ Violation logged');

        // Step 2: Show notification
        print('🎮 🛡️ Step 2: Showing notification...');
        await _showGameBlockedNotification(gameName);
        print('🎮 🛡️ Step 2: ✅ Notification shown');

      } else {
        // Track *all* allowed launches, not just unlock key
        final sessionId = await _ensureGameSessionActive(packageName, gameName);
        if (sessionId != null) {
          _startBackgroundSessionUpdates(packageName, gameName, sessionId);
        }
      }

      print('🎮 🛡️ === GAME DETECTION COMPLETE ===');
    } catch (e) {
      print('🎮 ❌ Error handling enhanced game detection: $e');
      debugConnectionId(); // Debug on error
      print('🎮 ❌ Stack trace: ${e.toString()}');
    }
  }

  static void _startBackgroundSessionUpdates(String packageName, String gameName, String sessionId) {
    // If a timer already exists for this package, do nothing
    if (_heartbeatTimersByPackage.containsKey(packageName)) return;

    final timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      try {
        if (_connectionId == null) {
          t.cancel();
          _heartbeatTimersByPackage.remove(packageName);
          return;
        }
        final docRef = FirebaseFirestore.instance
            .collection('game_sessions')
            .doc(_connectionId)
            .collection('sessions')
            .doc(sessionId);

        final snap = await docRef.get();
        if (!snap.exists) {
          t.cancel();
          _heartbeatTimersByPackage.remove(packageName);
          return;
        }

        final data = snap.data()!;
        final bool isActive = data['isActive'] ?? true;
        if (!isActive) {
          t.cancel();
          _heartbeatTimersByPackage.remove(packageName);
          print('⏹️ Session ended on backend, stopping background updates ($packageName).');
          return;
        }

        final launchedAt = (data['launchedAt'] as Timestamp?)?.toDate();
        final playTimeSeconds = launchedAt != null
            ? DateTime.now().difference(launchedAt).inSeconds
            : (data['totalPlayTimeSeconds'] ?? 0);

        await docRef.update({
          'lastUpdateAt': FieldValue.serverTimestamp(),
          'heartbeat': FieldValue.serverTimestamp(),
          'totalPlayTimeSeconds': playTimeSeconds,
        });
      } catch (e) {
        print('Error in heartbeat timer for $packageName: $e');
      }
    });

    _heartbeatTimersByPackage[packageName] = timer;
  }

// Stop background timer when game is closed:
  static void _stopBackgroundSessionUpdates() {
    _backgroundSessionUpdateTimer?.cancel();
    _backgroundSessionUpdateTimer = null;
    _backgroundActiveGamePackage = null;
  }

  // Stop enhanced monitoring
  static Future<void> stopEnhancedMonitoring() async {
    print('🎮 🛡️ Stopping enhanced background monitoring');

    _isMonitoring = false;
    _monitoringTimer?.cancel();
    _connectionIdRefreshTimer?.cancel();

    try {
      // Cancel background tasks
      await Workmanager().cancelByUniqueName(ENHANCED_MONITOR_TASK);

      // Stop enhanced native service
      await _backgroundChannel.invokeMethod('stopEnhancedService');

      // Clear monitoring preferences
      await MonitoringPreferences.clearMonitoringState();

      print('🎮 🛡️ Enhanced monitoring stopped successfully');
    } catch (e) {
      print('🎮 ❌ Error stopping enhanced monitoring: $e');
    }
  }

  // Background task method
  static Future<void> checkEnhancedGamesInBackground({Map<String, dynamic>? inputData}) async {
    try {
      print('🎮 🛡️ Enhanced background task: Checking games');
      print('🔍 Input data: $inputData');

      // Initialize Firebase for background task
      await Firebase.initializeApp();

      if (inputData != null) {
        if (inputData.containsKey('connectionId') && inputData['connectionId'] != null) {
          String newConnectionId = inputData['connectionId'];
          print('🔍 Setting connectionId from inputData: "$newConnectionId"');
          _connectionId = newConnectionId;
        }
        if (inputData.containsKey('currentDeviceId') && inputData['currentDeviceId'] != null) {
          _currentDeviceId = inputData['currentDeviceId'];
        }
        if (inputData.containsKey('monitoredGames')) {
          _monitoredGames = Set<String>.from(inputData['monitoredGames'] ?? []);
        }
        if (inputData.containsKey('allowedGames')) {
          _allowedGames = Set<String>.from(inputData['allowedGames'] ?? []);
        }
      }

      // If no connectionId in inputData, try to fetch it
      if (_connectionId == null || _connectionId!.isEmpty) {
        print('🔍 No connectionId in background task, attempting to fetch...');
        await _loadConnectionIdFromPreferences();

        if (_connectionId == null || _connectionId!.isEmpty) {
          await _fetchAndSetConnectionId();
        }
      }

      // Debug after setting values
      debugConnectionId();

      // Reload current permissions from Firestore if we have connectionId
      if (_connectionId != null && _connectionId!.isNotEmpty) {
        await _loadGamePermissions();
      } else {
        print('🎮 ❌ Background task: No valid connectionId available');
      }

      print('🎮 🛡️ Enhanced background task completed');
    } catch (e) {
      print('🎮 ❌ Enhanced background task error: $e');
      debugConnectionId(); // Debug on error
    }
  }

  static Future<void> testViolationLogging() async {
    print('🔍 === TESTING VIOLATION LOGGING ===');
    debugConnectionId();

    if (_connectionId == null) {
      print('🔍 ConnectionId is null, attempting to fetch...');
      await _fetchAndSetConnectionId();
    }

    if (_connectionId == null) {
      print('🔍 Still no connectionId, cannot test violation logging');
      return;
    }

    try {
      await _logEnhancedViolation('test.package.name', 'Test Game');
      print('🔍 Test violation logging succeeded');
    } catch (e) {
      print('🔍 Test violation logging failed: $e');
    }
  }

  // Force update game permissions (call this when schedule changes)
  static Future<void> forceUpdatePermissions() async {
    if (!_isMonitoring) return;

    if (_connectionId == null || _connectionId!.isEmpty) {
      await _fetchAndSetConnectionId();
    }

    if (_connectionId != null) {
      print('🎮 🛡️ Force updating game permissions');
      await _loadGamePermissions();
    }
  }

  // Emergency stop all blocking
  static Future<void> emergencyStop() async {
    try {
      print('🎮 🛡️ 🚨 EMERGENCY STOP TRIGGERED');

      await _backgroundChannel.invokeMethod('emergencyStop');
      await stopEnhancedMonitoring();

      print('🎮 🛡️ Emergency stop completed');
    } catch (e) {
      print('🎮 ❌ Error during emergency stop: $e');
    }
  }

  // Get game name from package name
  static Future<String> _getGameName(String packageName) async {
    try {
      List<AppInfo> apps = await InstalledApps.getInstalledApps(false, false);
      for (var app in apps) {
        if (app.packageName == packageName) {
          return app.name ?? packageName;
        }
      }
    } catch (e) {
      print('🎮 ❌ Error getting game name: $e');
    }
    return packageName;
  }

  // Log enhanced violation
  static Future<void> _logEnhancedViolation(String packageName, String gameName) async {
    try {

      if (_connectionId == null || _connectionId!.isEmpty) {
        print('🎮 ❌ Cannot log violation: connectionId is null or empty');
        print('🔍 Debug: _connectionId = $_connectionId');

        // Try to fetch connectionId one more time before giving up
        await _fetchAndSetConnectionId();

        if (_connectionId == null || _connectionId!.isEmpty) {
          print('🎮 ❌ Still no connectionId after fetch attempt');

          // Try to log this issue for debugging
          await FirebaseFirestore.instance
              .collection('debug_connectionid_issues')
              .add({
            'packageName': packageName,
            'gameName': gameName,
            'connectionId': _connectionId,
            'currentDeviceId': _currentDeviceId,
            'connectionIdIsNull': _connectionId == null,
            'connectionIdIsEmpty': _connectionId?.isEmpty ?? true,
            'isMonitoring': _isMonitoring,
            'timestamp': FieldValue.serverTimestamp(),
          });

          return;
        }
      }

      print('🎮 🛡️ Attempting to save violation for: $gameName with connectionId: $_connectionId');

      // Try to save violation with retry logic
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          await FirebaseFirestore.instance
              .collection('violations')
              .doc(_connectionId)
              .set({
            'connectionId': _connectionId,
            'childDeviceId': _currentDeviceId != null ? 'child_android_$_currentDeviceId' : 'child_android_enhanced',
            'childName': 'Child Device',
            'gameName': gameName,
            'packageName': packageName,
            'violationType': 'enhanced_unauthorized_launch',
            'timestamp': FieldValue.serverTimestamp(),
            'detectedAt': FieldValue.serverTimestamp(),
            'description': 'Game launched outside app - enhanced blocking active',
            'blockingMethod': 'enhanced_overlay_and_aggressive',
            'severity': 'high',
            'screenLock': false,
            'blockedSuccessfully': true,
            'deviceType': 'android',
            'monitoringLevel': 'enhanced',
            'actionTaken': 'game_blocked_immediately',
          }, SetOptions(merge: true)); // Optional: merge so you don't overwrite other fields

          return; // Success, exit retry loop

        } catch (e) {
          print('🎮 ❌ Attempt $attempt failed to save violation: $e');
          if (attempt == 3) {
            throw e; // Last attempt failed
          }
          await Future.delayed(Duration(seconds: attempt)); // Wait before retry
        }
      }
    } catch (e) {
      print('🎮 ❌ Final error logging enhanced violation: $e');
      print('🎮 ❌ Stack trace: ${e.toString()}');

      // Try to save basic error info to a different collection
      try {
        await FirebaseFirestore.instance
            .collection('violation_errors')
            .add({
          'connectionId': _connectionId ?? 'unknown',
          'currentDeviceId': _currentDeviceId,
          'gameName': gameName,
          'packageName': packageName,
          'error': e.toString(),
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (errorLogError) {
        print('🎮 ❌ Failed to log violation error: $errorLogError');
      }
    }
  }

  // Show game blocked notification
  static Future<void> _showGameBlockedNotification(String gameName) async {
    try {
      final FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();

      // Initialize notification plugin if not already done
      const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

      const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);

      await notifications.initialize(initializationSettings);

      // Create notification channel first
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        'enhanced_game_blocked_channel',
        'Enhanced Game Blocking',
        description: 'Notifications when games are blocked by enhanced system',
        importance: Importance.max,
      );

      await notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'enhanced_game_blocked_channel',
        'Enhanced Game Blocking',
        channelDescription: 'Notifications when games are blocked by enhanced system',
        importance: Importance.max,
        priority: Priority.max,
        ongoing: false, // Changed from true to false
        autoCancel: true, // Changed from false to true
        showWhen: true,
        color: Color(0xFFFF0000),
        playSound: true,
        enableVibration: true,
        fullScreenIntent: false, // Changed from true to false to prevent overlay issues
        category: AndroidNotificationCategory.alarm,
        icon: '@mipmap/ic_launcher', // Ensure proper icon
      );

      const NotificationDetails details = NotificationDetails(android: androidDetails);

      // Use unique notification ID based on timestamp
      int notificationId = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      await notifications.show(
        notificationId,
        '🛡️ GAME BLOCKED',
        '$gameName was blocked by iCTRL parental controls',
        details,
      );

      print('🎮 🛡️ Showed enhanced blocking notification for: $gameName');
    } catch (e) {
      print('🎮 ❌ Error showing enhanced blocking notification: $e');
    }
  }

  // Check if enhanced monitoring is active
  static bool get isEnhancedMonitoring => _isMonitoring;

  // Get monitored games count
  static int get monitoredGamesCount => _monitoredGames.length;

  // Get currently allowed games count
  static int get allowedGamesCount => _allowedGames.length;

  // Get blocked games count
  static int get blockedGamesCount => _monitoredGames.length - _allowedGames.length;

  // Get current connectionId (for debugging)
  static String? get currentConnectionId => _connectionId;

  // Get current device ID (for debugging)
  static String? get currentDeviceId => _currentDeviceId;
}

@pragma('vm:entry-point')
void enhancedCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print('🎮 🛡️ Enhanced background task executed: $task');

    try {
      WidgetsFlutterBinding.ensureInitialized();
      await Firebase.initializeApp();
      // Ensure proper initialization
      if (!WidgetsBinding.instance.isRootWidgetAttached) {
        WidgetsFlutterBinding.ensureInitialized();
      }

      switch (task) {
        case EnhancedBackgroundGameMonitor.ENHANCED_MONITOR_TASK:
          await EnhancedBackgroundGameMonitor.checkEnhancedGamesInBackground(inputData: inputData);
          break;
        default:
          print('🎮 ❌ Unknown enhanced background task: $task');
          return Future.value(false);
      }
      return Future.value(true);
    } catch (e) {
      print('🎮 ❌ Enhanced background task error: $e');
      // Don't return false immediately, log the error to Firestore if possible
      try {
        if (inputData != null && inputData.containsKey('connectionId')) {
          await FirebaseFirestore.instance
              .collection('background_task_errors')
              .add({
            'connectionId': inputData['connectionId'],
            'taskType': task,
            'error': e.toString(),
            'timestamp': FieldValue.serverTimestamp(),
            'deviceType': 'android_enhanced',
          });
        }
      } catch (logError) {
        print('🎮 ❌ Failed to log background task error: $logError');
      }
      return Future.value(false);
    }
  });

}