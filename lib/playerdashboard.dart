import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io';
import 'qrscanner.dart';
import 'package:installed_apps/installed_apps.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'package:installed_apps/app_info.dart';
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:external_app_launcher/external_app_launcher.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'services/background_game_monitor.dart';
import 'services/monitoring_preferences.dart';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'playeraccountmanagement.dart';

class PlayerDashboard extends StatefulWidget{
  const PlayerDashboard({Key? key}) : super(key: key);

  @override
  State<PlayerDashboard> createState() => _PlayerDashboardState();
}

class _PlayerDashboardState extends State<PlayerDashboard> with WidgetsBindingObserver, TickerProviderStateMixin{
  bool _hasShownUnlockTutorial = false;

  int _selectedIndex = 2;
  String _username = "Loading...";
  String? _currentDeviceId;
  Map<String, dynamic> _deviceInfo = {};
  bool _isLoading = true;

  // New variables for paired devices
  List<ConnectedDevice> _connectedDevices = [];
  bool _isLoadingDevices = true;
  bool _hasPairedDevices = false;
  String? _connectionId;
  Map<String, dynamic>? _connectionData;

  List<GameSchedule> _gameSchedules = [];
  bool _isLoadingSchedules = false;
  bool _hasScheduleError = false;
  String _scheduleErrorMessage = '';
  List<GameSchedule> _archivedSchedules = [];
  bool _showArchivedSchedules = false;

  List<GameSession> _activeGameSessions = [];
  bool _endingSession = false;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _gameSessionsListener;
  bool _isLoadingActiveSessions = false;
  Timer? _sessionEndDelay;
  bool _isShowingEndedSession = false;
  GameSession? _recentlyEndedSession;
  Timer? _gameStatusCheckTimer;

  Timer? _scheduleRefreshTimer;
  StreamSubscription<DocumentSnapshot>? _scheduleStreamSubscription;

  Timer? _scheduleEnforcementTimer;
  DateTime? _currentGameEndTime;
  String? _currentScheduledGameName;
  bool _isScreenLocked = false;
  bool get isScreenLocked => _isScreenLocked;
  bool _waitingForParentUnlock = false;
  StreamSubscription? _parentUnlockSubscription;
  bool _hasNewScheduleNotification = false;

  static const MethodChannel _backgroundMonitorChannel =
  MethodChannel('com.ictrl.ictrl/background_monitor');
  bool _isEnhancedMonitoringActive = false;
  bool _hasUsageStatsPermission = false;

  StreamSubscription<DocumentSnapshot>? _allowedGamesStreamSubscription;
  String? _selectedBonusCategory;
  StreamSubscription<DocumentSnapshot>? _tasksStreamSubscription;

  StreamSubscription<DocumentSnapshot>? _pointsStreamSubscription;
  int _currentPoints = 0;

  String getWeeklyBonusPrefsKey(DateTime now) =>
      "bonus_task_${now.year}_week${getIsoWeekNumber(now)}";

  int getIsoWeekNumber(DateTime date) {
    // Returns ISO week number (1-53)
    final firstDayOfYear = DateTime(date.year, 1, 1);
    final daysOffset = firstDayOfYear.weekday - 1;
    final firstMonday = firstDayOfYear.subtract(Duration(days: daysOffset));
    final diff = date.difference(firstMonday);
    return (diff.inDays / 7).ceil();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    print('🎮 App lifecycle changed to: $state');

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      // App is going to background or being closed
        _handleAppPaused();
        break;
      case AppLifecycleState.resumed:
      // App is coming back to foreground
        _handleAppResumed();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  void _handleAppPaused() {
    print('🎮 App paused');

    // Don't do anything if screen is locked
    if (_isScreenLocked) return;

    // Cancel any pending game status check since user left the app
    _gameStatusCheckTimer?.cancel();
    _gameStatusCheckTimer = null;

    // Check if we have active game sessions
    if (_activeGameSessions.isNotEmpty) {
      print('🎮 Active game session detected - will NOT end session automatically');
      print('🎮 Game sessions should only end when explicitly detected that game closed');

      // Schedule enforcement continues running in background
      print('🎮 ⏰ Schedule enforcement continues running in background');

      return;
    }

    print('🎮 No active game sessions - scheduling session end with delay');
    _scheduleDelayedSessionEnd();
  }

// Modified _handleAppResumed to check schedule enforcement
  void _handleAppResumed() async {
    print('🎮 App resumed');
    if (_isScreenLocked) return;
    _cancelDelayedSessionEnd();

    if (_currentGameEndTime != null && DateTime.now().isAfter(_currentGameEndTime!)) {
      print('🎮 ⏰ Schedule time has passed while app was in background');
      _enforceScreenLock('', _currentScheduledGameName ?? 'Unknown Game');
      return;
    }

    if (_activeGameSessions.isNotEmpty) {
      final activeSession = _activeGameSessions.first;
      bool isRunning = await _isAppCurrentlyRunning(activeSession.packageName);
      if (isRunning) {
        print('🎮 Game is running, resume session updates');
        // Pass the session id (NOT the connectionId)
        _startSessionUpdates(activeSession.id, activeSession.gameName);
      } else {
        print('🎮 Game is NOT running, ending session');
        await _endActiveGameSession();
      }
    }

    _stopGameProcessMonitoring();
    _startGameSessionsListener();
  }

// Method to get remaining time for current scheduled game (for UI display)
  Duration? getCurrentGameRemainingTime() {
    if (_currentGameEndTime == null) return null;

    final now = DateTime.now();
    if (now.isAfter(_currentGameEndTime!)) return Duration.zero;

    return _currentGameEndTime!.difference(now);
  }

  void _scheduleGameStatusCheck() {
    // Cancel any existing check
    _gameStatusCheckTimer?.cancel();

    print('🎮 Scheduling game status check after 10 seconds');

    // Wait 10 seconds to see if user goes back to the game
    _gameStatusCheckTimer = Timer(Duration(seconds: 2), () async {
      final currentState = WidgetsBinding.instance.lifecycleState;

      if (currentState == AppLifecycleState.resumed && _activeGameSessions.isNotEmpty) {
        // User has stayed in our app for 10 seconds, likely closed the game
        print('🎮 User stayed in app for 10 seconds - checking if game is still running');

        final activeSession = _activeGameSessions.first;
        bool isGameStillRunning = await _isAppCurrentlyRunning(activeSession.packageName);

        if (!isGameStillRunning) {
          print('🎮 Game ${activeSession.gameName} is no longer running - ending session');
          await _handleGameClosed(activeSession);
        } else {
          print('🎮 Game ${activeSession.gameName} is still running - keeping session active');
        }
      } else {
        print('🎮 App went to background again or no active sessions - cancelling check');
      }

      _gameStatusCheckTimer = null;
    });
  }

  void _scheduleDelayedSessionEnd() {
    // Cancel any existing timer first
    _cancelDelayedSessionEnd();

    print('🎮 Starting 30-second delay timer for session end');

    // Use a single Timer.delayed instead of Timer.periodic
    _sessionEndDelay = Timer(const Duration(seconds: 30), () async {
      print('🎮 30-second delay completed, checking app state');

      // Double-check the app state before ending session
      final currentState = WidgetsBinding.instance.lifecycleState;
      print('🎮 Current app state during delayed end: $currentState');

      // Only end session if app is still not in foreground
      if (currentState != AppLifecycleState.resumed && _activeGameSessions.isNotEmpty) {
        print('🎮 App still in background after 30 seconds, ending session');
        await _handleDelayedSessionEnd();
      } else {
        print('🎮 App resumed or no active sessions, not ending session');
      }

      // Clear the timer reference
      _sessionEndDelay = null;
    });
  }

  void _cancelDelayedSessionEnd() {
    if (_sessionEndDelay != null) {
      print('🎮 Cancelling delayed session end timer');
      _sessionEndDelay!.cancel();
      _sessionEndDelay = null;
    } else {
      print('🎮 No delayed session end timer to cancel');
    }
  }

  Future<void> _handleDelayedSessionEnd() async {
    print('🎮 Handling delayed session end');
    if (_activeGameSessions.isEmpty) {
      print('🎮 No active sessions to end');
      return;
    }

    if (_isEnhancedMonitoringActive) {
      print('🎮 Enhanced monitoring is active, skipping delayed session end.');
      return;
    }

    final lastActiveSession = _activeGameSessions.first;

    // CHECK: Is the game process still running?
    bool stillRunning = await _isAppCurrentlyRunning(lastActiveSession.packageName);
    if (stillRunning) {
      print('🎮 Game process still running, NOT ending session.');
      return; // Don't end session if game is still running!
    }

    // Otherwise, proceed to end session
    final playTime = DateTime.now().difference(lastActiveSession.launchedAt);
    setState(() {
      _recentlyEndedSession = GameSession(
        id: lastActiveSession.id,
        gameName: lastActiveSession.gameName,
        packageName: lastActiveSession.packageName,
        launchedAt: lastActiveSession.launchedAt,
        childDeviceId: lastActiveSession.childDeviceId,
        deviceInfo: lastActiveSession.deviceInfo,
        isActive: false,
        playTime: playTime,
      );
      _isShowingEndedSession = true;
    });
    await GameplayNotificationService.showGameEndNotification(
      lastActiveSession.gameName,
      playTime,
    );
    await _endActiveGameSession();
  }

  @override
  void initState() {
    super.initState();

    GameplayNotificationService.initialize();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      if (args != null) {
        _connectionId = args['connectionId'];
        _connectionData = args['connectionData'];
        _deviceInfo = args['deviceInfo'] ?? {};
      }

      await _initializeUserData();
      _loadGameSchedules();

      if (_deviceInfo.isEmpty) {
        _deviceInfo = await _getDeviceInfo();
        print('🎮 Device info loaded: $_deviceInfo');
      }

      if (_connectionId == null) {
        print('🎮 Connection ID not provided, fetching from paired devices...');
        _connectionId = await _fetchConnectionIdFromPairedDevices();
        print('🎮 Fetched connection ID: $_connectionId');
      }

      _testInstalledAppsPlugin();
      _initializeConnectionData();

      // Load recent session BEFORE starting listeners
      await _loadRecentSession();

      await resetExpiredUnlocks();

      // Start real-time listeners
      _startScheduleListener();
      _startGameSessionsListener();
      _initializeEnhancedMonitoring();
      _checkUsageStatsPermission();
      _startAllowedGamesListener();
      _startTasksListener();
      _startPointsListener();

    });

    Timer.periodic(Duration(seconds: 10), (timer) {
      _updateFinishedSchedulesToArchived();
    });
  }

  Future<void> _initializeEnhancedMonitoring() async {
    try {
      await EnhancedBackgroundGameMonitor.initialize();

      if (_connectionId != null) {
        await _startEnhancedMonitoring();
      }
    } catch (e) {
      print('❌ Error initializing enhanced monitoring: $e');
    }
  }

  Future<void> _checkUsageStatsPermission() async {
    try {
      const platform = MethodChannel('com.ictrl.ictrl/app_monitor');
      _hasUsageStatsPermission = await platform.invokeMethod('hasUsageStatsPermission');
      print('🎮 📋 Usage Stats Permission: $_hasUsageStatsPermission');
    } catch (e) {
      print('🎮 ❌ Error checking usage stats permission: $e');
      _hasUsageStatsPermission = false;
    }
  }

  Future<void> _startEnhancedMonitoring() async {
    try {

      print('🎮 🛡️ Connection test passed, starting enhanced monitoring...');
      await EnhancedBackgroundGameMonitor.startEnhancedMonitoring(_connectionId!);

      setState(() {
        _isEnhancedMonitoringActive = true;
      });

      print('🎮 🛡️ Enhanced monitoring started successfully');
    } catch (e) {
      print('❌ Error starting enhanced monitoring: $e');

      // Show user-friendly error
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start monitoring. Please check your internet connection.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _startPointsListener() {
    if (_connectionId == null) return;

    _pointsStreamSubscription?.cancel();

    _pointsStreamSubscription = FirebaseFirestore.instance
        .collection('accumulated_points')
        .doc(_connectionId!)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists && snapshot.data() != null && snapshot['points'] != null) {
        setState(() {
          _currentPoints = snapshot['points'] as int;
        });
      }
    });
  }

  void _startTasksListener() {
    if (_connectionId == null) return;

    _tasksStreamSubscription?.cancel(); // Clean up any prior listener

    _tasksStreamSubscription = FirebaseFirestore.instance
        .collection('task_and_rewards')
        .doc(_connectionId!)
        .snapshots()
        .listen(
          (DocumentSnapshot snapshot) {
        print('🎯 Real-time update for tasks received');
        _processTasksSnapshot(snapshot);
      },
      onError: (error) {
        print('🎯 Task listener error: $error');
      },
    );
  }

  void _processTasksSnapshot(DocumentSnapshot snapshot) {
    if (!snapshot.exists || snapshot.data() == null) {
      setState(() {
        _tasksAndRewards = [];
        _isLoadingTasks = false;
      });
      return;
    }
    final data = snapshot.data() as Map<String, dynamic>;
    final tasks = (data['tasks'] as List?) ?? [];
    final String playerDeviceId = 'child_android_${getCurrentDeviceId()}';
    List<TaskReward> fetchedTasks = tasks
        .where((t) => t['childDeviceId'] == playerDeviceId)
        .map((t) => TaskReward(
      id: t['scheduleId'] ?? '',
      task: t['task'] ?? '',
      reward: '${t['reward']['points']} pts',
      status: t['reward']['status'] ?? 'Pending',
      isCompleted: t['reward']['status'] == 'completed',
      updatedAt: t['updatedAt'] != null
          ? (t['updatedAt'] as Timestamp).toDate()
          : null,
    ))
        .toList();
    setState(() {
      _tasksAndRewards = fetchedTasks;
      _isLoadingTasks = false;
    });
  }

  Future<void> _stopBackgroundMonitoring() async {
    try {
      if (!_isEnhancedMonitoringActive) return;

      print('🎮 🛑 Stopping background monitoring');

      await EnhancedBackgroundGameMonitor.stopEnhancedMonitoring();

      setState(() {
        _isEnhancedMonitoringActive = false;
      });

      print('🎮 ✅ Background monitoring stopped');
    } catch (e) {
      print('🎮 ❌ Error stopping background monitoring: $e');
    }
  }

  Future<void> refreshAfterPairing() async {
    await _fetchPairedDevices();

    // Auto-start schedule loading/listening after pairing
    if (_hasPairedDevices && _connectionId != null) {
      // Option A: Use real-time listener (recommended)
      _startScheduleListener();

      _startScheduleListener();

      await _loadGameSchedules();
    }
  }

  void _startScheduleListener() {
    if (_connectionId == null) return;

    _scheduleStreamSubscription?.cancel();

    print('🎮 Starting real-time schedule listener for connectionId: $_connectionId');

    // Listen to the specific document that contains the schedules array
    _scheduleStreamSubscription = FirebaseFirestore.instance
        .collection('gaming_scheduled')
        .doc(_connectionId!)
        .snapshots()
        .listen(
          (DocumentSnapshot snapshot) {
        print('🎮 Real-time update received, document exists: ${snapshot.exists}');
        // This will update the UI without showing loading states
        _processScheduleSnapshot(snapshot);
      },
      onError: (error) {
        print('🎮 Schedule listener error: $error');
        setState(() {
          _hasScheduleError = true;
          _scheduleErrorMessage = 'Real-time sync error: $error';
        });
      },
    );
  }

  String extractStatus(Map<String, dynamic> scheduleMap) {
    if (scheduleMap['status'] != null) {
      return scheduleMap['status'].toString().toLowerCase();
    }
    if (scheduleMap['recurringDays'] != null &&
        scheduleMap['recurringDays']['status'] != null) {
      return scheduleMap['recurringDays']['status'].toString().toLowerCase();
    }
    return "";
  }

  void _processScheduleSnapshot(DocumentSnapshot snapshot) {
    try {
      List<GameSchedule> activeSchedules = [];
      List<GameSchedule> archivedSchedules = [];

      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>?;

        if (data != null && data['schedules'] != null) {
          List<dynamic> schedulesArray = data['schedules'];

          for (var scheduleData in schedulesArray) {
            try {
              final scheduleMap = scheduleData as Map<String, dynamic>;
              GameSchedule schedule = GameSchedule.fromParentData(scheduleMap);

              // Only include active schedules
              final status = extractStatus(scheduleMap);
              final isArchived = [
                "finished", "missed", "passed", "completed", "cancelled"
              ].contains(status);

              if (scheduleMap['isActive'] == true && !isArchived) {
                activeSchedules.add(schedule);
              } else if (isArchived) {
                archivedSchedules.add(schedule);
              }
            } catch (e) {
              print('🎮 Error converting schedule: $e');
            }
          }
        }
      }

      setState(() {
        _gameSchedules = activeSchedules;
        _archivedSchedules = archivedSchedules;
        if (_isLoadingSchedules) {
          _isLoadingSchedules = false;
        }
        _hasScheduleError = false;
        _scheduleErrorMessage = '';
      });

      print('🎮 Schedules updated via real-time listener: ${activeSchedules.length} active, ${archivedSchedules.length} archived');
      GameplayNotificationService.updateSchedules(activeSchedules);

    } catch (e) {
      print('🎮 Error processing schedule snapshot: $e');
      setState(() {
        _hasScheduleError = true;
        _scheduleErrorMessage = 'Failed to process schedule updates: $e';
      });
    }
  }

  Future<void> _enforceScreenLock(String packageName, String gameName) async {
    await GameplayNotificationService.showGameTimeUpNotification(gameName);
    await _endActiveGameSession();
    // DO NOT show ScreenLockOverlay or lock UI
  }

  Future<void> _updateFinishedSchedulesToArchived() async {
    if (_connectionId == null || _connectionId!.isEmpty) return;

    DocumentSnapshot doc = await FirebaseFirestore.instance
        .collection('gaming_scheduled')
        .doc(_connectionId!)
        .get();

    if (!doc.exists) return;

    final data = doc.data() as Map<String, dynamic>?;
    if (data == null || data['schedules'] == null) return;

    List<dynamic> schedules = List.from(data['schedules']);
    bool anyChanges = false;
    DateTime now = DateTime.now();

    for (var schedule in schedules) {
      if (schedule['scheduledDate'] == null || schedule['endTime'] == null) continue;

      final scheduledDate = (schedule['scheduledDate'] as Timestamp).toDate();
      final endTimeParts = schedule['endTime'].toString().split(':');
      final endHour = int.parse(endTimeParts[0]);
      final endMinute = int.parse(endTimeParts[1]);
      final endDateTime = DateTime(
        scheduledDate.year,
        scheduledDate.month,
        scheduledDate.day,
        endHour,
        endMinute,
      );

      if (now.isAfter(endDateTime)) {
        // Schedule has ended
        if (schedule['status'] != 'completed' || schedule['isActive'] != false) {
          schedule['status'] = 'completed'; // or "finished"
          schedule['isActive'] = false;
          anyChanges = true;
        }
      }
    }

    if (anyChanges) {
      await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .update({
        'schedules': schedules,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> _initializeUserData() async {
    try {
      // Get device info if not provided from pairing
      if (_deviceInfo.isEmpty) {
        final deviceInfo = await _getDeviceInfo();
        setState(() {
          _deviceInfo = deviceInfo;
        });
      }

      // Fetch username from Firestore
      final username = await _fetchUsernameFromFirestore(_deviceInfo);
      setState(() {
        _username = username ?? "Player";
        _isLoading = false;
      });

      // Fetch paired devices using connectionId if available
      await _fetchPairedDevices();

      // Fetch installed games
      await _fetchInstalledGames();

      // Fetch tasks and rewards after device pairing status is determined
      await _fetchTasksAndRewards();
    } catch (e) {
      print('Error initializing user data: $e');
      setState(() {
        _username = "Player";
        _isLoading = false;
        _isLoadingDevices = false;
        _isLoadingTasks = false;
        _isLoadingGames = false;
      });
    }
  }

  Future<void> _initializeConnectionData() async {
    try {
      print('🎮 Initializing connection data...');

      // Make sure device info is initialized first
      await _initializeUserData();

      // First, try to get connectionId from route arguments (existing logic)
      final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      if (args != null && args['connectionId'] != null) {
        _connectionId = args['connectionId'];
        _connectionData = args['connectionData'];
        _deviceInfo = args['deviceInfo'] ?? {};
        print('🎮 ✅ Got connectionId from route arguments: $_connectionId');
      } else {
        print('🎮 ⚠️ No connectionId in route arguments, fetching from paired_devices...');

        // Fetch connectionId from paired_devices collection
        final fetchedConnectionId = await _fetchConnectionIdFromPairedDevices();
        if (fetchedConnectionId != null) {
          _connectionId = fetchedConnectionId;
          print('🎮 ✅ Successfully fetched connectionId: $_connectionId');
        } else {
          print('🎮 ❌ Failed to fetch connectionId from paired_devices');
          setState(() {
            _hasScheduleError = true;
            _scheduleErrorMessage = 'Could not establish device connection';
          });
          return;
        }
      }

      // Once we have connectionId, proceed with other initialization
      await _testInstalledAppsPlugin();
      await _loadGameSchedules();

      // Start real-time listeners
      _startScheduleListener();

    } catch (e) {
      print('🎮 ❌ Error in _initializeConnectionData: $e');
      setState(() {
        _hasScheduleError = true;
        _scheduleErrorMessage = 'Failed to initialize connection: $e';
      });
    }
  }

  Future<String?> _fetchConnectionIdFromPairedDevices() async {
    try {
      print('🎮 Starting to fetch connectionId from paired_devices...');

      // Get current device ID using your existing method
      final currentDeviceId = getCurrentDeviceId();
      if (currentDeviceId.isEmpty) {
        print('🎮 ❌ Could not get current device ID - device info might not be initialized');
        return null;
      }

      print('🎮 Current device ID: $currentDeviceId');

      // Create the child device ID with the proper prefix
      final childDeviceId = 'child_android_$currentDeviceId';
      print('🎮 Looking for childDeviceId: $childDeviceId');

      // Query paired_devices collection to find document where current device is paired
      final QuerySnapshot pairedDevicesSnapshot = await FirebaseFirestore.instance
          .collection('paired_devices')
          .where('childDeviceId', isEqualTo: childDeviceId)
          .get();

      print('🎮 Found ${pairedDevicesSnapshot.docs.length} paired device records');

      if (pairedDevicesSnapshot.docs.isNotEmpty) {
        // Get the first matching document (should only be one)
        final DocumentSnapshot doc = pairedDevicesSnapshot.docs.first;
        final data = doc.data() as Map<String, dynamic>?;

        if (data != null) {
          // The connectionId is the document ID itself
          String connectionId = doc.id;

          print('🎮 ✅ Found connectionId: $connectionId');
          print('🎮 Paired device data: $data');

          // Update the paired devices status
          setState(() {
            _hasPairedDevices = true;
          });

          return connectionId;
        } else {
          print('🎮 ❌ Paired device document has no data');
          return null;
        }
      } else {
        print('🎮 ❌ No paired device found for childDeviceId: $childDeviceId');

        // Debug: Let's see all paired devices to understand the structure
        print('🎮 DEBUG: Checking all paired devices...');
        final QuerySnapshot allPairedDevices = await FirebaseFirestore.instance
            .collection('paired_devices')
            .get();

        print('🎮 Total paired devices in collection: ${allPairedDevices.docs.length}');
        for (var doc in allPairedDevices.docs) {
          final data = doc.data() as Map<String, dynamic>?;
          print('🎮 - Document ID: ${doc.id}');
          print('🎮 - Data: $data');
          if (data != null) {
            print('🎮 - childDeviceId: ${data['childDeviceId']}');
            print('🎮 - parentDeviceId: ${data['parentDeviceId']}');
          }
        }

        // Set paired devices status to false
        setState(() {
          _hasPairedDevices = false;
          _connectedDevices = [];
        });

        return null;
      }

    } catch (e, stackTrace) {
      print('🎮 ❌ Error fetching connectionId from paired_devices: $e');
      print('🎮 Stack trace: $stackTrace');

      // Set error state
      setState(() {
        _hasPairedDevices = false;
        _connectedDevices = [];
      });

      return null;
    }
  }

  Future<String?> getCurrentConnectionId() async {
    return await _fetchConnectionIdFromPairedDevices();
  }

  Future<void> _loadGameSchedules() async {
    setState(() {
      _isLoadingSchedules = true;
      _hasScheduleError = false;
      _scheduleErrorMessage = '';
    });

    try {
      if (!_hasPairedDevices || _connectionId == null) {
        setState(() {
          _gameSchedules = [];
          _archivedSchedules = [];
          _isLoadingSchedules = false;
        });
        GameplayNotificationService.updateSchedules([]);
        return;
      }

      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .get();

      List<GameSchedule> activeSchedules = [];
      List<GameSchedule> archivedSchedules = [];

      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>?;
        if (data != null && data['schedules'] != null) {
          List<dynamic> schedulesArray = data['schedules'];
          for (var scheduleData in schedulesArray) {
            try {
              final scheduleMap = scheduleData as Map<String, dynamic>;
              GameSchedule schedule = GameSchedule.fromParentData(scheduleMap);

              final status = schedule.status.toLowerCase();
              final isArchived = [
                "finished", "missed", "passed", "completed", "cancelled"
              ].contains(status);

              if (scheduleMap['isActive'] == true && !isArchived) {
                activeSchedules.add(schedule);
              } else if (isArchived) {
                archivedSchedules.add(schedule);
              }
            } catch (e) {
              print('❌ Error converting schedule: $e');
            }
          }
        }
      }

      setState(() {
        _gameSchedules = activeSchedules;
        _archivedSchedules = archivedSchedules;
        _isLoadingSchedules = false;
      });

      GameplayNotificationService.updateSchedules(activeSchedules);

    } catch (e, stackTrace) {
      setState(() {
        _hasScheduleError = true;
        _scheduleErrorMessage = 'Failed to load game schedules: $e';
        _isLoadingSchedules = false;
      });

      GameplayNotificationService.updateSchedules([]);
    }
  }

  Future<void> _fetchInstalledGames() async {
    try {
      setState(() {
        _isLoadingGames = true;
      });

      if (!Platform.isAndroid) {
        print('Installed apps fetching is only supported on Android');
        setState(() {
          _isLoadingGames = false;
        });
        return;
      }

      bool hasPermission = await _requestInstalledAppsPermission();
      if (!hasPermission) {
        print('Permission denied to access installed apps');
        setState(() {
          _isLoadingGames = false;
        });
        return;
      }

      print('Fetching apps with enhanced icon handling...');
      List<AppInfo> apps = [];

      try {
        // Try to get apps with icons
        apps = await InstalledApps.getInstalledApps(
          true, // include icons
          false, // no system apps
        );
        print('Successfully fetched ${apps.length} apps with icons');
      } catch (e) {
        print('Failed to fetch apps with icons: $e');
        // Fallback to apps without icons
        apps = await InstalledApps.getInstalledApps(
          false, // no icons
          false, // no system apps
        );
        print('Using apps without icons as fallback');
      }

      // Filter and create game objects with enhanced icon handling
      final List<InstalledGame> games = [];
      int gameCount = 0;
      int rejectedCount = 0;

      for (AppInfo app in apps) {
        if (_isGameApp(app)) {
          try {
            final game = await _createInstalledGameWithEnhancedIcons(app);
            games.add(game);
            gameCount++;
            print('✓ Added game: ${game.name} (${app.packageName})');
          } catch (e) {
            print('✗ Failed to create game object for ${app.name}: $e');
          }
        } else {
          rejectedCount++;
        }
      }

      print('Game detection complete:');
      print('- Total apps scanned: ${apps.length}');
      print('- Games found: $gameCount');
      print('- Apps rejected: $rejectedCount');

      setState(() {
        _installedGames = games;
        _isLoadingGames = false;
      });

      // Save to Firestore and optionally upload icons to Storage
      await _saveInstalledGamesToFirestore(games);

      // Optional: Upload icons to Firebase Storage for cloud backup
      // await GameIconService.batchUploadIcons(games);

    } catch (e) {
      print('Error fetching installed games: $e');
      setState(() {
        _isLoadingGames = false;
      });
    }
  }

  Future<InstalledGame> _createInstalledGameWithEnhancedIcons(AppInfo app) async {
    try {
      final String appName = (app.name ?? 'Unknown App').toLowerCase();
      final String packageName = app.packageName ?? '';

      // Determine category and fallback icon
      String category = _determineGameCategory(appName, packageName);
      IconData fallbackIcon = _determineFallbackIcon(appName);

      // Enhanced icon handling
      GameIconData? iconData;
      Uint8List? iconBytes;
      String? iconBase64;
      String? iconStorageUrl;

      // Get icon using the enhanced service
      try {
        iconData = await GameIconService.getGameIcon(packageName, appName);

        if (iconData.iconBytes != null) {
          iconBytes = iconData.iconBytes;
          iconBase64 = base64Encode(iconBytes!);
          print('✓ Successfully processed icon for ${app.name}');
        } else if (iconData.storageUrl != null) {
          iconStorageUrl = iconData.storageUrl;
          print('✓ Using storage URL for ${app.name}');
        }
      } catch (e) {
        print('✗ Error getting enhanced icon for ${app.name}: $e');
      }

      // Fallback to original method if enhanced method fails
      if (iconData == null && app.icon != null && app.icon!.isNotEmpty) {
        try {
          iconBytes = app.icon!;
          iconBase64 = base64Encode(iconBytes!);
          print('✓ Using fallback icon method for ${app.name}');
        } catch (e) {
          print('✗ Error processing fallback icon for ${app.name}: $e');
          iconBytes = null;
          iconBase64 = null;
        }
      }

      // Check if game is allowed
      bool isAllowed = await _checkIfGameIsAllowed(packageName);

      return InstalledGame(
        name: app.name ?? 'Unknown App',
        category: category,
        timeSpent: "0 minutes today",
        icon: fallbackIcon,
        isAllowed: isAllowed,
        packageName: packageName,
        iconBytes: iconBytes,
        iconBase64: iconBase64,
        iconStorageUrl: iconStorageUrl,
        iconData: iconData,
      );
    } catch (e) {
      print('Error creating game object for ${app.name}: $e');
      // Return basic game object on error
      return InstalledGame(
        name: app.name ?? 'Unknown App',
        category: 'Game',
        timeSpent: "0 minutes today",
        icon: Icons.games,
        isAllowed: true,
        packageName: app.packageName ?? '',
        iconBytes: null,
        iconBase64: null,
      );
    }
  }

  Future<bool> _requestInstalledAppsPermission() async {
    try {
      if (!Platform.isAndroid) {
        return false;
      }

      // For Android 11+ (API 30+), you need QUERY_ALL_PACKAGES permission in manifest
      // Check if we can access installed apps
      try {
        final testApps = await InstalledApps.getInstalledApps(false, false);
        print('Permission check passed - found ${testApps.length} apps');
        return true;
      } catch (e) {
        print('Initial permission check failed: $e');

        // Try requesting various permissions that might be needed
        Map<Permission, PermissionStatus> permissions = await [
          Permission.storage,
          Permission.manageExternalStorage,
        ].request();

        // Check if any permission was granted
        bool hasAnyPermission = permissions.values.any((status) => status.isGranted);

        if (hasAnyPermission) {
          // Try again after getting permissions
          try {
            final testApps = await InstalledApps.getInstalledApps(false, false);
            print('Permission check passed after requesting - found ${testApps.length} apps');
            return true;
          } catch (e) {
            print('Still failed after requesting permissions: $e');
            return false;
          }
        }

        return false;
      }
    } catch (e) {
      print('Error in permission request: $e');
      return false;
    }
  }

  bool _isGameApp(AppInfo app) {
    if (app.name == null || app.packageName == null) {
      return false;
    }

    final String appName = app.name!.toLowerCase();
    final String packageName = app.packageName!.toLowerCase();

    // First, exclude known non-game apps that might have gaming keywords
    final List<String> excludedApps = [
      'paypal', 'billease', 'gcash', 'maya', 'paymaya', 'bpi', 'bdo', 'metrobank',
      'unionbank', 'digiwards', 'sketchware', 'android studio', 'visual studio',
      'unity hub', 'unreal engine', 'figma', 'canva', 'photoshop', 'premiere',
      'discord', 'telegram', 'whatsapp', 'messenger', 'viber', 'zoom', 'teams',
      'chrome', 'firefox', 'opera', 'edge', 'safari', 'youtube', 'netflix',
      'spotify', 'apple music', 'facebook', 'instagram', 'twitter', 'tiktok',
      'shopee', 'lazada', 'grab', 'uber', 'waze', 'google maps', 'calculator',
      'clock', 'calendar', 'notes', 'camera', 'gallery', 'settings', 'file manager'
    ];

    // Check if app is in excluded list
    for (String excluded in excludedApps) {
      if (appName.contains(excluded) || packageName.contains(excluded)) {
        return false;
      }
    }

    // Exclude system and utility package patterns
    final List<String> excludedPackagePatterns = [
      'com.android.', 'com.google.android.', 'com.samsung.android.',
      'com.miui.', 'com.xiaomi.', 'com.huawei.', 'com.oppo.', 'com.vivo.',
      'com.paypal.', 'com.gcash.', 'com.paymaya.', 'com.unionbank.',
      'com.bpi.', 'com.bdo.', 'com.metrobank.', 'com.sketchware.',
      'com.discord.', 'com.whatsapp.', 'com.facebook.', 'com.instagram.',
      'com.twitter.', 'com.tiktok.', 'com.shopee.', 'com.lazada.',
      'com.grab.', 'com.uber.', 'com.waze.', 'com.spotify.', 'com.netflix.'
    ];

    for (String pattern in excludedPackagePatterns) {
      if (packageName.startsWith(pattern)) {
        return false;
      }
    }

    // Check for definitive game package patterns (more specific)
    final List<String> gamePublishers = [
      'com.supercell.', 'com.roblox.', 'com.mojang.', 'com.epicgames.',
      'com.kiloo.', 'com.king.', 'com.ea.', 'com.gameloft.', 'com.activision.',
      'com.tencent.ig', 'com.tencent.tmgp', 'com.mihoyo.', 'com.rovio.',
      'com.netmarble.', 'com.outfit7.', 'com.halfbrick.', 'com.playdemic.',
      'com.sgn.', 'com.zynga.', 'com.playrix.', 'com.gameinsight.',
      'com.glu.', 'com.jam.', 'com.nianticlabs.', 'com.miniclip.',
      'com.ubisoft.', 'com.square_enix.', 'com.bandainamco.'
    ];

    bool hasGamePublisher = gamePublishers.any((publisher) =>
        packageName.startsWith(publisher));

    // Check for game-specific keywords (more targeted)
    final List<String> specificGameKeywords = [
      'minecraft', 'roblox', 'fortnite', 'clash of clans', 'clash royale',
      'candy crush', 'pokemon go', 'among us', 'fall guys', 'call of duty',
      'pubg', 'mobile legends', 'free fire', 'genshin impact', 'honkai',
      'brawl stars', 'geometry dash', 'temple run', 'subway surfers',
      'angry birds', 'plants vs zombies', 'asphalt', 'need for speed',
      'fifa mobile', 'nba 2k', 'madden', 'mortal kombat', 'tekken',
      'street fighter', 'dragon ball', 'naruto', 'one piece'
    ];

    bool hasSpecificGameKeyword = specificGameKeywords.any((keyword) =>
    appName.contains(keyword) || packageName.contains(keyword));

    // Check for generic game patterns in package name
    bool hasGamePackagePattern =
        packageName.contains('.games.') ||
            packageName.contains('.game.') ||
            packageName.endsWith('.game') ||
            packageName.endsWith('.games');

    // Check for game categories in app name (be more specific)
    final List<String> gameCategories = [
      'rpg', 'mmorpg', 'fps', 'moba', 'battle royale', 'racing game',
      'puzzle game', 'strategy game', 'tower defense', 'card game',
      'board game', 'casino game', 'arcade game', 'platformer',
      'adventure game', 'action game', 'simulation game', 'sports game'
    ];

    bool hasGameCategory = gameCategories.any((category) =>
        appName.contains(category));

    // More restrictive game detection
    return hasGamePublisher || hasSpecificGameKeyword ||
        (hasGamePackagePattern && (hasGameCategory ||
            appName.contains('game') || appName.contains('play')));
  }

  Future<void> _testInstalledAppsPlugin() async {
    try {
      print('Testing installed apps plugin...');

      // Try to get just a few apps without icons first
      final List<AppInfo> testApps = await InstalledApps.getInstalledApps(
        false, // no icons
        false, // no system apps
      );

      print('Test successful: Found ${testApps.length} apps');

      if (testApps.isNotEmpty) {
        print('Sample app: ${testApps.first.name} (${testApps.first.packageName})');
      }

      // Now try with icons
      final List<AppInfo> testAppsWithIcons = await InstalledApps.getInstalledApps(
        true, // with icons
        false, // no system apps
      );


      print('Test with icons successful: Found ${testAppsWithIcons.length} apps');

    } catch (e) {
      print('Installed apps plugin test failed: $e');
    }
  }

  Future<bool> _checkIfGameIsAllowed(String packageName) async {

    try {
      // Step 1: Check device ID
      String deviceId = getCurrentDeviceId();
      print('📱 Device ID: "$deviceId" (isEmpty: ${deviceId.isEmpty})');

      if (deviceId.isEmpty) {
        print('❌ RESULT: ALLOWED - No device ID found');
        return true;
      }

      // Step 2: Check connection ID using your actual method
      String? connectionId = await _fetchConnectionIdFromPairedDevices();
      print('🔗 Connection ID: "$connectionId" (isNull: ${connectionId == null}, isEmpty: ${connectionId?.isEmpty ?? true})');

      if (connectionId == null || connectionId.isEmpty) {
        print('❌ RESULT: ALLOWED - No connection ID found');
        return true;
      }

      // Step 3: Check if document exists
      print('📄 Checking Firestore document: allowed_games/$connectionId');
      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('allowed_games')
          .doc(connectionId)
          .get();

      print('📄 Document exists: ${doc.exists}');

      if (!doc.exists) {
        print('❌ RESULT: ALLOWED - No parental control document exists');
        return true;
      }

      // Step 4: Parse document data
      Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
      List<dynamic> allowedGames = data['allowedGames'] ?? [];

      print('📋 Total games in parent config: ${allowedGames.length}');
      print('📋 Parent config data keys: ${data.keys.toList()}');

      // Step 5: Print all configured games for comparison
      print('📋 All configured games:');
      for (int i = 0; i < allowedGames.length; i++) {
        var game = allowedGames[i];
        String gameName = game['gameName'] ?? 'NO_NAME';
        bool isAllowed = game['isGameAllowed'] ?? false;
        print('   [$i] "$gameName" -> ${isAllowed ? "ALLOWED" : "BLOCKED"}');
      }

      print('🔍 Searching for exact match: "$packageName"');

      for (int i = 0; i < allowedGames.length; i++) {
        var game = allowedGames[i];
        String configuredGameName = game['gameName'] ?? '';
        String configuredPackageName = game['packageName'] ?? ''; // ADD THIS LINE
        bool isGameAllowed = game['isGameAllowed'] ?? false;

        // CHANGE THIS CONDITION TO USE packageName
        if (configuredPackageName == packageName) {
          print('✅ FOUND MATCH! Game $packageName -> ${isGameAllowed ? "ALLOWED" : "BLOCKED"}');
          return isGameAllowed;
        }
      }
      return false;
    } catch (e, stackTrace) {
      return true;
    } finally {
    }
  }

  Future<GameSchedulePermission> _checkGamePermission(String gameName) async {
    try {
      final now = DateTime.now();

      // Find active schedules for the current time
      for (var schedule in _gameSchedules) {
        if (schedule.gameName == gameName && schedule.dateTime != null) {
          final scheduleDate = schedule.dateTime!;
          final today = DateTime(now.year, now.month, now.day);
          final scheduleDay = DateTime(scheduleDate.year, scheduleDate.month, scheduleDate.day);

          // Check if schedule is for today
          if (scheduleDay == today) {
            // Parse start and end times
            final timeParts = schedule.time.split(' - ');
            if (timeParts.length == 2) {
              final startTime = _parseTime(timeParts[0]);
              final endTime = _parseTime(timeParts[1]);

              if (startTime != null && endTime != null) {
                final startDateTime = DateTime(now.year, now.month, now.day, startTime.hour, startTime.minute);
                final endDateTime = DateTime(now.year, now.month, now.day, endTime.hour, endTime.minute);

                if (now.isAfter(startDateTime) && now.isBefore(endDateTime)) {
                  return GameSchedulePermission(
                    isAllowed: true,
                    reason: 'Available now until ${timeParts[1]}',
                    schedule: schedule,
                    remainingTime: endDateTime.difference(now),
                  );
                } else if (now.isBefore(startDateTime)) {
                  return GameSchedulePermission(
                    isAllowed: false,
                    reason: 'Available later at ${timeParts[0]}',
                    schedule: schedule,
                    remainingTime: startDateTime.difference(now),
                  );
                }
              }
            }
          }
        }
      }

      return GameSchedulePermission(
        isAllowed: false,
        reason: 'This scheduled is finished',
        schedule: null,
        remainingTime: null,
      );
    } catch (e) {
      print('Error checking game permission: $e');
      return GameSchedulePermission(
        isAllowed: false,
        reason: 'Permission check failed',
        schedule: null,
        remainingTime: null,
      );
    }
  }

  TimeOfDay? _parseTime(String timeString) {
    try {
      final parts = timeString.split(':');
      if (parts.length == 2) {
        final hour = int.parse(parts[0]);
        final minute = int.parse(parts[1]);
        return TimeOfDay(hour: hour, minute: minute);
      }
    } catch (e) {
      print('Error parsing time: $timeString - $e');
    }
    return null;
  }

  Future<void> _launchGame(String packageName, String gameName) async {
    try {
      // Check if screen is currently locked
      if (_isScreenLocked) {
        _showScreenLockDialog(gameName);
        return;
      }

      // Check if this game should be blocked (outside schedule or not allowed)
      bool shouldBlock = await _shouldBlockGame(packageName, gameName);
      if (shouldBlock) {
        return; // Don't launch - blocking dialog already shown
      }

      // Continue with normal launch
      final permission = await _checkGamePermission(gameName);
      if (permission.isAllowed) {
        print('🎮 Attempting to launch game: $gameName ($packageName)');

        var isInstalled = await LaunchApp.isAppInstalled(
          androidPackageName: packageName,
        );

        if (isInstalled) {
          // Track the launch BEFORE opening the app
          await _trackGameLaunch(packageName, gameName);

          // Show gameplay notification
          await GameplayNotificationService.showGameStartNotification(gameName, packageName);

          var result = await LaunchApp.openApp(
            androidPackageName: packageName,
          );

          print('🎮 ✅ Successfully launched: $gameName');

          // START SCHEDULE ENFORCEMENT (warnings only, not blocking)
          if (permission.remainingTime != null) {
            _startScheduleEnforcement(gameName, packageName, permission.remainingTime!);
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.play_circle_fill, color: Colors.green),
                  const SizedBox(width: 8),
                  Text('$gameName is now running'),
                ],
              ),
              backgroundColor: Colors.green.withOpacity(0.8),
              duration: const Duration(seconds: 2),
            ),
          );

        } else {
          print('🎮 ❌ App not installed: $gameName');
          _showGameLaunchErrorDialog(gameName);
        }
      }
    } catch (e) {
      print('🎮 ❌ Error launching game $gameName: $e');
      _showGameLaunchErrorDialog(gameName);
    }
  }

  void _startScheduleEnforcement(String gameName, String packageName, Duration remainingTime) {
    // Cancel any existing enforcement timer
    _stopScheduleEnforcement();

    // Set the end time for current game
    _currentGameEndTime = DateTime.now().add(remainingTime);
    _currentScheduledGameName = gameName;

    // Set timer to lock screen when time is up
    _scheduleEnforcementTimer = Timer(remainingTime, () async {
      await _enforceScreenLock(packageName, gameName);
    });
  }

  Future<bool> _shouldBlockGame(String packageName, String gameName) async {
    // Check if parent has allowed the game
    bool isAllowed = await _checkIfGameIsAllowed(packageName);
    if (isAllowed) {
      // Parent has explicitly allowed this game; don't block, regardless of schedule/time!
      print('🚦 Parent ALLOW override: $gameName ($packageName) is allowed by parent');
      return false;
    }

    // Otherwise, check schedule enforcement (time and day matches)
    final permission = await _checkGamePermission(gameName);
    if (!permission.isAllowed) {
      String reason = permission.reason;
      print('⏰ Game $gameName blocked by schedule: $reason');
      _showOutsideScheduleWarning(gameName, reason);
      return true;
    }

    // Fallback: not blocked
    return false;
  }

  void _showOutsideScheduleWarning(String gameName, String reason) {
    showDialog(
      context: context,
      barrierDismissible: false, // Cannot dismiss when playing outside schedule
      builder: (BuildContext context) {
        return WillPopScope(
          onWillPop: () async => false,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            title: Row(
              children: [
                Icon(
                  Icons.warning_amber,
                  color: Colors.red,
                  size: 32,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Playing Outside Schedule',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You are playing "$gameName" outside your scheduled time.',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  reason,
                  style: TextStyle(
                    color: Colors.orange,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your parent will be notified of this violation.',
                        style: TextStyle(
                          color: Colors.red.shade300,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Please stop playing and return to your scheduled activities.',
                        style: TextStyle(
                          color: Colors.red.shade300,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Your parent will handle any necessary actions.',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 13,
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
                  'I Understand',
                  style: TextStyle(
                    color: const Color(0xFFE8956C),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showScreenLockDialog(String gameName) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return WillPopScope(
          onWillPop: () async => false,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            title: Row(
              children: [
                Icon(
                  Icons.lock_outline,
                  color: Colors.red,
                  size: 32,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Screen Locked',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Access to "$gameName" has been restricted.',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Only your parent can unlock this screen.',
                        style: TextStyle(
                          color: Colors.red.shade300,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ask them to unlock it from their device.',
                        style: TextStyle(
                          color: Colors.red.shade300,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_waitingForParentUnlock)
                  Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Waiting for parent to unlock...',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            // NO "I Understand" button - only parent can unlock
            actions: [],
          ),
        );
      },
    );
  }

  void _stopScheduleEnforcement() {
    if (_scheduleEnforcementTimer != null) {
      print('🎮 ⏰ Stopping schedule enforcement timer');
      _scheduleEnforcementTimer!.cancel();
      _scheduleEnforcementTimer = null;
    }

    _currentGameEndTime = null;
    _currentScheduledGameName = null;
  }

  void _startGameSessionsListener() {
    if (_connectionId == null) return;

    print('🎮 Starting game sessions listener for connection: $_connectionId');
    _gameSessionsListener?.cancel();

    setState(() => _isLoadingActiveSessions = true);

    _gameSessionsListener = FirebaseFirestore.instance
        .collection('game_sessions')
        .doc(_connectionId!)
        .collection('sessions')
        .where('isActive', isEqualTo: true)
        .orderBy('launchedAt', descending: true)
        .limit(1)
        .snapshots()
        .listen(
          (query) {
        if (!mounted) return;
        if (query.docs.isNotEmpty) {
          final doc = query.docs.first;
          setState(() {
            _activeGameSessions = [GameSession.fromFirestore(doc)];
            _currentSessionId = doc.id; // keep in sync
            _isLoadingActiveSessions = false;
          });
        } else {
          setState(() {
            _activeGameSessions = [];
            _currentSessionId = null;
            _isLoadingActiveSessions = false;
          });
        }
        print('🎮 Updated active game session (subcollection listener)');
      },
      onError: (error) {
        // IMPORTANT: clear stale UI so "LIVE" doesn't stick
        print('🎮 Error in game sessions listener: $error');
        if (!mounted) return;
        setState(() {
          _activeGameSessions = [];
          _currentSessionId = null;
          _isLoadingActiveSessions = false;
        });
      },
    );
  }

  void _startAllowedGamesListener() {
    if (_connectionId == null) return;

    _allowedGamesStreamSubscription?.cancel();

    _allowedGamesStreamSubscription = FirebaseFirestore.instance
        .collection('allowed_games')
        .doc(_connectionId!)
        .snapshots()
        .listen((DocumentSnapshot snapshot) async {
      print('🎮 Allowed games document updated (real-time)');

      // Parse package names from parent document
      final Set<String> allowedPackages = <String>{};
      if (snapshot.exists && snapshot.data() != null) {
        final data = snapshot.data() as Map<String, dynamic>;
        final List<dynamic> allowedGames = data['allowedGames'] ?? [];
        for (final g in allowedGames) {
          try {
            if (g is Map<String, dynamic>) {
              final pkg = (g['packageName'] ?? '').toString().trim();
              final isAllowed = g['isGameAllowed'] == true;
              if (isAllowed && pkg.isNotEmpty) allowedPackages.add(pkg);
            }
          } catch (e) {
            print('🎮 Error reading entry in allowedGames: $e');
          }
        }
      }

      // Optional: compute monitored packages (where you want native to watch)
      final List<String> monitoredPackages =
      _installedGames.map((g) => g.packageName).where((p) => p.isNotEmpty).toList();

      // Debug log exactly what you'll send to native
      print('🎮 🛡️ Sending to native -> monitored=${monitoredPackages.length}, allowed=${allowedPackages.length}');
      print('🎮 🛡️ allowedPackages: $allowedPackages');

      // Send to native
      try {
        await _backgroundMonitorChannel.invokeMethod('updateGamePermissions', {
          'connectionId': _connectionId,
          'monitoredGames': monitoredPackages,
          'allowedGames': allowedPackages.toList(),
        });
        print('🎮 🛡️ Updated native service with game permissions');
      } catch (e) {
        print('🎮 ❌ Error invoking native updateGamePermissions: $e');
      }

      // Rebuild UI list (existing behavior)
      await _fetchInstalledGames();
    },
        onError: (error) {
          print('❌ Allowed games listener error: $error');
        });
  }

  Future<void> _trackGameLaunch(String packageName, String gameName) async {
    try {
      if (_connectionId != null) {
        final sessionsCollection = FirebaseFirestore.instance
            .collection('game_sessions')
            .doc(_connectionId)
            .collection('sessions');
        final now = DateTime.now();

        // Always create a new session document for each launch
        final newSessionRef = sessionsCollection.doc();
        await newSessionRef.set({
          'sessionId': newSessionRef.id,
          'connectionId': _connectionId,
          'childDeviceId': 'child_android_${getCurrentDeviceId()}',
          'gameName': gameName,
          'packageName': packageName,
          'launchedAt': now,
          'deviceInfo': _deviceInfo,
          'isActive': true,
          'lastUpdateAt': now,
          'heartbeat': now,
          'source': 'app',
        });

        // Optionally, save newSessionRef.id as _currentSessionId for live updates/timer
        _currentSessionId = newSessionRef.id;
        _startSessionUpdates(newSessionRef.id, gameName);
      }
    } catch (e) {
      print('Error tracking game launch: $e');
    }
  }

  Timer? _sessionUpdateTimer;
  String? _currentSessionId;
  Timer? _realTimeUpdateTimer;
  Timer? _gameProcessMonitor;

  void _startSessionUpdates(String sessionId, String gameName) {
    _stopSessionUpdates(); // Stop any existing timer

    print('🎮 Starting session updates for $gameName');

    // Update every 10 seconds for real-time heartbeat
    _realTimeUpdateTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      // Only continue if connection exists and app is still active
      if (_connectionId != null && _activeGameSessions.isNotEmpty) {
        _updateGameSession(sessionId, gameName);
      } else {
        print('🎮 Stopping session updates - no connection or active sessions');
        timer.cancel();
      }
    });
  }

  void _stopSessionUpdates() {
    if (_realTimeUpdateTimer != null) {
      print('🎮 Stopping session update timer');
      _realTimeUpdateTimer!.cancel();
      _realTimeUpdateTimer = null;
    }
  }

// Updates the heartbeat and play time of a given session.
  Future<void> _updateGameSession(String sessionId, String gameName) async {
    try {
      if (_connectionId == null) return;
      final sessionDoc = FirebaseFirestore.instance
          .collection('game_sessions')
          .doc(_connectionId)
          .collection('sessions')
          .doc(sessionId);

      final docSnap = await sessionDoc.get();
      print('DEBUG _updateGameSession: BEFORE UPDATE: ${docSnap.data()}');

      if (docSnap.exists) {
        final data = docSnap.data()!;
        final isActive = data['isActive'] ?? true;

        if (!isActive) {
          print('🎮 Session is no longer active, stopping updates');
          _stopSessionUpdates();
          return;
        }

        final launchedAt = (data['launchedAt'] as Timestamp?)?.toDate();
        if (launchedAt != null) {
          final currentPlayTimeSeconds = DateTime.now().difference(launchedAt).inSeconds;
          print('DEBUG _updateGameSession: UPDATING totalPlayTimeSeconds=$currentPlayTimeSeconds');
          await sessionDoc.update({
            'lastUpdateAt': FieldValue.serverTimestamp(),
            'heartbeat': FieldValue.serverTimestamp(),
            'totalPlayTimeSeconds': currentPlayTimeSeconds,
          });

          final afterDoc = await sessionDoc.get();
          print('DEBUG _updateGameSession: AFTER UPDATE: ${afterDoc.data()}');
          print('🎮 Updated session heartbeat for $gameName - Play time: ${currentPlayTimeSeconds}s');
        }
      } else {
        print('🎮 Session document not found, stopping updates');
        _stopSessionUpdates();
      }
    } catch (e) {
      print('Error updating game session: $e');
    }
  }

// Ends the currently active session for the current connectionId and sessionId
  Future<void> _endActiveGameSession() async {
    try {
      if (_connectionId == null || _currentSessionId == null) return;

      // Prevent duplicate session end calls
      if (_endingSession) return;
      _endingSession = true;

      // Stop all timers first
      _stopSessionUpdates();
      _stopGameProcessMonitoring();
      _gameStatusCheckTimer?.cancel();
      _gameStatusCheckTimer = null;
      _updateFinishedSchedulesToArchived();

      final sessionDoc = FirebaseFirestore.instance
          .collection('game_sessions')
          .doc(_connectionId)
          .collection('sessions')
          .doc(_currentSessionId);

      final docSnap = await sessionDoc.get();
      print('DEBUG _endActiveGameSession: BEFORE END: ${docSnap.data()}');

      if (docSnap.exists) {
        final data = docSnap.data()!;
        var launchedAt = (data['launchedAt'] as Timestamp?)?.toDate();
        var lastPlayTime = data['totalPlayTimeSeconds'] ?? 0;

        // Defensive: If launchedAt is missing or too recent, delay and retry
        if (launchedAt == null || DateTime.now().difference(launchedAt).inSeconds < 3) {
          print('⚠ launchedAt not set or too recent, delaying session end for 2 seconds');
          await Future.delayed(Duration(seconds: 2));
          final retriedDoc = await sessionDoc.get();
          launchedAt = (retriedDoc.data()?['launchedAt'] as Timestamp?)?.toDate();
          lastPlayTime = retriedDoc.data()?['totalPlayTimeSeconds'] ?? lastPlayTime;
          if (launchedAt == null) {
            print('⚠ launchedAt still not set, aborting session end');
            _endingSession = false;
            return;
          }
        }

        final endedAt = DateTime.now();
        final calculatedPlayTime = endedAt.difference(launchedAt).inSeconds;
        final finalPlayTime = calculatedPlayTime > lastPlayTime ? calculatedPlayTime : lastPlayTime;

        await sessionDoc.update({
          'isActive': false,
          'endedAt': Timestamp.fromDate(endedAt),
          'totalPlayTimeSeconds': finalPlayTime,
          'lastUpdateAt': FieldValue.serverTimestamp(),
          'showAsRecent': true,
        });

        await GameplayNotificationService.cancelGameplayNotifications();
        print('🎮 Ended active session with total play time: ${finalPlayTime}s');

        await _loadRecentSession();
      }

      final afterDoc = await sessionDoc.get();
      print('DEBUG _endActiveGameSession: AFTER END: ${afterDoc.data()}');
      _endingSession = false;
    } catch (e) {
      print('Error ending active session: $e');
      _endingSession = false;
    }
  }

// Gets the latest session document for the current connectionId
  Future<GameSession?> _getLatestSession() async {
    if (_connectionId == null) return null;
    final sessionsCollection = FirebaseFirestore.instance
        .collection('game_sessions')
        .doc(_connectionId)
        .collection('sessions');
    final latestQuery = await sessionsCollection
        .orderBy('launchedAt', descending: true)
        .limit(1)
        .get();
    if (latestQuery.docs.isNotEmpty) {
      return GameSession.fromFirestore(latestQuery.docs.first);
    }
    return null;
  }

  Future<void> _loadRecentSession() async {
    try {
      if (_connectionId == null) return;
      final recentQuery = await FirebaseFirestore.instance
          .collection('game_sessions')
          .doc(_connectionId!)
          .collection('sessions')
          .where('isActive', isEqualTo: false)
          .orderBy('endedAt', descending: true)
          .limit(1)
          .get();

      if (recentQuery.docs.isNotEmpty) {
        final doc = recentQuery.docs.first;
        _recentlyEndedSession = GameSession.fromFirestore(doc);
        _isShowingEndedSession = true;
        if (mounted) setState(() {});
      } else {
        if (mounted) {
          setState(() {
            _recentlyEndedSession = null;
            _isShowingEndedSession = false;
          });
        }
      }
    } catch (e) {
      print('Error loading recent session: $e');
      if (mounted) {
        setState(() {
          _recentlyEndedSession = null;
          _isShowingEndedSession = false;
        });
      }
    }
  }

  void _showGameNotAllowedDialog(String gameName, String reason) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2D3748),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: Row(
            children: [
              Icon(
                Icons.warning,
                color: Colors.orange,
                size: 24,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: const Text(
                  'Game Not Available',
                  style: TextStyle(color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sorry, "$gameName" is not available right now.',
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              Text(
                reason,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 14,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'OK',
                style: TextStyle(color: Color(0xFFE8956C)),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showGameLaunchErrorDialog(String gameName) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2D3748),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: Row(
            children: [
              Icon(
                Icons.error_outline,
                color: Colors.red,
                size: 24,
              ),
              const SizedBox(width: 10),
              const Text(
                'Launch Failed',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
          content: Text(
            'Unable to launch "$gameName". Please make sure the game is installed.',
            style: const TextStyle(color: Colors.white),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'OK',
                style: TextStyle(color: Color(0xFFE8956C)),
              ),
            ),
          ],
        );
      },
    );
  }

  void _stopGameProcessMonitoring() {
    if (_gameProcessMonitor != null) {
      print('🎮 Stopping game process monitoring');
      _gameProcessMonitor!.cancel();
      _gameProcessMonitor = null;
    }
  }

  Future<bool> _isAppCurrentlyRunning(String packageName) async {
    try {
      print('🎮 Checking if $packageName is currently running');

      // Option 1: Use platform channel for accurate detection
      try {
        const platform = MethodChannel('com.ictrl.ictrl/process_monitor');
        final bool isRunning = await platform.invokeMethod('isAppRunning', {'packageName': packageName});
        print('🎮 Platform channel result: $packageName is ${isRunning ? 'running' : 'not running'}');
        return isRunning;
      } on PlatformException catch (e) {
        print('🎮 Platform channel error: ${e.message}, using fallback method');
      } catch (e) {
        print('🎮 Platform channel not available: $e, using fallback method');
      }

      // Option 2: Fallback - assume game is not running if we're checking
      // This happens when user has been in our app for 10+ seconds
      print('🎮 Using fallback: since user stayed in our app, assuming game was closed');
      return false;

    } catch (e) {
      print('🎮 Error checking if app is running: $e');
      return false;
    }
  }

  Future<void> _handleGameClosed(GameSession gameSession) async {
    try {
      final playTime = DateTime.now().difference(gameSession.launchedAt);

      setState(() {
        _recentlyEndedSession = GameSession(
          id: gameSession.id,
          gameName: gameSession.gameName,
          packageName: gameSession.packageName,
          launchedAt: gameSession.launchedAt,
          childDeviceId: gameSession.childDeviceId,
          deviceInfo: gameSession.deviceInfo,
          isActive: false,
          playTime: playTime,
        );
        _isShowingEndedSession = true;
      });

      await GameplayNotificationService.showGameEndNotification(
        gameSession.gameName,
        playTime,
      );

      await _endActiveGameSession();
    } catch (e) {
      print('🎮 Error handling game closed: $e');
    }
  }

  Future<String?> _getGamePackageName(String gameName) async {
    try {
      print('🎮 Looking for package name for game: $gameName');

      if (_connectionId == null) {
        print('🎮 ❌ No connection ID available');
        return null;
      }

      // First, try to find in local _installedGames list (faster)
      for (var game in _installedGames) {
        if (game.name.toLowerCase() == gameName.toLowerCase()) {
          print('🎮 ✅ Found package name in local list: ${game.packageName}');
          return game.packageName;
        }
      }

      print('🎮 🔍 Game not found locally, checking Firestore...');

      // Query the installed_games collection using connectionId
      DocumentSnapshot installedGamesDoc = await FirebaseFirestore.instance
          .collection('installed_games')
          .doc(_connectionId!)
          .get();

      if (!installedGamesDoc.exists) {
        print('🎮 ❌ No installed_games document found for connectionId: $_connectionId');
        return null;
      }

      final data = installedGamesDoc.data() as Map<String, dynamic>?;
      if (data == null || !data.containsKey('games')) {
        print('🎮 ❌ No games array found in installed_games document');
        return null;
      }

      List<dynamic> games = data['games'];
      print('🎮 📱 Found ${games.length} games in Firestore');

      // Search through the games array
      for (var gameData in games) {
        if (gameData is Map<String, dynamic>) {
          final gameNameFromDb = gameData['name'] as String?;
          final packageName = gameData['packageName'] as String?;

          print('🎮 Checking: "$gameNameFromDb" vs "$gameName"');

          if (gameNameFromDb != null && packageName != null) {
            // Try exact match first
            if (gameNameFromDb.toLowerCase() == gameName.toLowerCase()) {
              print('🎮 ✅ Found exact match: $packageName');
              return packageName;
            }

            // Try partial match (in case of slight name differences)
            if (gameNameFromDb.toLowerCase().contains(gameName.toLowerCase()) ||
                gameName.toLowerCase().contains(gameNameFromDb.toLowerCase())) {
              print('🎮 ✅ Found partial match: $packageName');
              return packageName;
            }
          }
        }
      }

      print('🎮 ❌ Game "$gameName" not found in installed games');
      return null;

    } catch (e, stackTrace) {
      print('🎮 ❌ Error getting package name for $gameName: $e');
      print('🎮 Stack trace: $stackTrace');
      return null;
    }
  }

  void _onGameScheduleTap(GameSchedule schedule) async {
    if (schedule.gameName == null) {
      _showGameLaunchErrorDialog('Unknown Game');
      return;
    }

    // Show loading indicator while fetching package name
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2D3748),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
              ),
              const SizedBox(height: 16),
              Text(
                'Launching ${schedule.gameName}...',
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        );
      },
    );

    try {
      // Try to get package name from Firestore
      String? packageName = await _getGamePackageName(schedule.gameName!);

      // Close loading dialog
      Navigator.of(context).pop();

      if (packageName == null) {
        print('🎮 ❌ Could not find package name for: ${schedule.gameName}');
        _showGameLaunchErrorDialog(schedule.gameName!);
        return;
      }

      print('🎮 📦 Found package name: $packageName for ${schedule.gameName}');
      await _launchGame(packageName, schedule.gameName!);

    } catch (e) {
      // Close loading dialog
      Navigator.of(context).pop();
      print('🎮 ❌ Error in _onGameScheduleTap: $e');
      _showGameLaunchErrorDialog(schedule.gameName!);
    }
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return "${duration.inHours}h ${duration.inMinutes.remainder(60)}m";
    } else {
      return "${duration.inMinutes}m";
    }
  }

  Future<void> _saveInstalledGamesToFirestore(List<InstalledGame> games) async {
    try {
      String deviceId = getCurrentDeviceId();
      if (deviceId.isEmpty) return;

      final DateTime now = DateTime.now();
      List<Map<String, dynamic>> gamesData = games.map((game) => {
        'name': game.name,
        'category': game.category,
        'packageName': game.packageName,
        'isAllowed': game.isAllowed,
        'iconStorageUrl': game.iconStorageUrl, // Include storage URL
        'lastDetected': Timestamp.fromDate(now),
      }).toList();

      await FirebaseFirestore.instance
          .collection('installed_games')
          .doc(_connectionId)
          .set({
        'games': gamesData,
        'lastUpdated': FieldValue.serverTimestamp(),
        'deviceId': deviceId,
        'totalGames': games.length,
      });

      print('Successfully saved ${games.length} games to Firestore');
    } catch (e) {
      print('Error saving games to Firestore: $e');
    }
  }

  String getCurrentDeviceId() {
    if (_deviceInfo.isEmpty) return '';

    if (Platform.isAndroid) {
      return _deviceInfo['androidId'] ?? '';
    } else if (Platform.isIOS) {
      return _deviceInfo['identifierForVendor'] ?? '';
    }
    return '';
  }

  final List<RedeemableReward> availableRewards = [
    RedeemableReward(
      id: "unlock_15min",
      name: "(15 Minutes)",
      cost: 200,
      description: "Unlock any game for 15 minutes.",
      icon: Icons.vpn_key,
      color: Colors.brown,
      duration: Duration(minutes: 15),
    ),
    RedeemableReward(
      id: "unlock_30min",
      name: "(30 Minutes)",
      cost: 500,
      description: "Unlock any game for 30 minutes.",
      icon: Icons.vpn_key,
      color: Colors.grey,
      duration: Duration(minutes: 30),
    ),
    RedeemableReward(
      id: "unlock_1h",
      name: "(1 Hour)",
      cost: 1000,
      description: "Unlock any game for 1 hour.",
      icon: Icons.vpn_key,
      color: Colors.amber,
      duration: Duration(hours: 1),
    ),
    RedeemableReward(
      id: "unlock_24h",
      name: "(24 Hours)",
      cost: 2000,
      description: "Unlock any game for 24 hours.",
      icon: Icons.vpn_key,
      color: Colors.blueAccent, // Or use a rainbow gradient widget if available
      duration: Duration(hours: 24),
    ),
  ];

  Future<Map<String, dynamic>> _getDeviceInfo() async {
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    Map<String, dynamic> deviceData = {};

    try {
      if (Platform.isAndroid) {
        final AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        deviceData = {
          'androidId': androidInfo.id,
          'brand': androidInfo.brand,
          'device': androidInfo.device,
          'fingerprint': androidInfo.fingerprint,
          'hardware': androidInfo.hardware,
          'isPhysicalDevice': androidInfo.isPhysicalDevice,
          'manufacturer': androidInfo.manufacturer,
          'model': androidInfo.model,
        };
      } else if (Platform.isIOS) {
        final IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        deviceData = {
          'identifierForVendor': iosInfo.identifierForVendor,
          'model': iosInfo.model,
          'name': iosInfo.name,
          'systemName': iosInfo.systemName,
          'systemVersion': iosInfo.systemVersion,
          'isPhysicalDevice': iosInfo.isPhysicalDevice,
        };
      }
    } catch (e) {
      print('Error getting device info: $e');
      deviceData = {'error': 'unknown_device'};
    }

    return deviceData;
  }

  Future<String?> _fetchUsernameFromFirestore(Map<String, dynamic> deviceData) async {
    try {
      final FirebaseFirestore firestore = FirebaseFirestore.instance;

      // Query the player_account collection to find matching device
      QuerySnapshot querySnapshot;

      if (Platform.isAndroid) {
        // Match Android device using multiple fields for better accuracy
        querySnapshot = await firestore
            .collection('player_account')
            .where('deviceInfo.androidId', isEqualTo: deviceData['androidId'])
            .where('deviceInfo.brand', isEqualTo: deviceData['brand'])
            .where('deviceInfo.model', isEqualTo: deviceData['model'])
            .limit(1)
            .get();
      } else if (Platform.isIOS) {
        // Match iOS device using identifier
        querySnapshot = await firestore
            .collection('player_account')
            .where('deviceInfo.identifierForVendor', isEqualTo: deviceData['identifierForVendor'])
            .limit(1)
            .get();
      } else {
        return null;
      }

      if (querySnapshot.docs.isNotEmpty) {
        final DocumentSnapshot doc = querySnapshot.docs.first;
        final Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        return data['username'] as String?;
      }

      // If no exact match found, you might want to handle device registration here
      // For now, return null to indicate no match found
      return null;
    } catch (e) {
      print('Error fetching username from Firestore: $e');
      return null;
    }
  }

  Future<void> _fetchPairedDevices() async {
    setState(() {
      _isLoadingDevices = true;
    });

    try {
      // Debug: Print connection ID and device info
      print('DEBUG: ConnectionId: $_connectionId');
      print('DEBUG: Device info: $_deviceInfo');

      // Use connectionId if available from pairing
      if (_connectionId != null && _connectionId!.isNotEmpty) {
        print('DEBUG: Using connectionId to fetch paired devices');

        // Query using the connectionId directly
        DocumentSnapshot pairingDoc = await FirebaseFirestore.instance
            .collection('paired_devices')
            .doc(_connectionId!)
            .get();

        if (pairingDoc.exists) {
          Map<String, dynamic> pairingData = pairingDoc.data() as Map<String, dynamic>;
          print('DEBUG: Found pairing using connectionId: $pairingData');

          setState(() {
            _hasPairedDevices = true;
          });

          // Create connected device objects based on the pairing data
          List<ConnectedDevice> devices = [];

          // Add parent device info (using the actual field names from your Firestore)
          if (pairingData['parentDeviceId'] != null) {
            String parentDeviceName = 'Parent Device';

            // Try to get parent device name from parentDeviceInfo if available
            if (pairingData['parentDeviceInfo'] != null) {
              Map<String, dynamic> parentInfo = pairingData['parentDeviceInfo'];
              if (parentInfo['brand'] != null && parentInfo['model'] != null) {
                parentDeviceName = '${parentInfo['brand']} ${parentInfo['model']}';
              }
            }

            devices.add(ConnectedDevice(
              id: pairingData['parentDeviceId'],
              name: parentDeviceName,
              deviceType: 'Parent Device',
              status: 'Online',
              icon: Icons.smartphone,
              lastSeen: DateTime.now(),
            ));
          }

          setState(() {
            _connectedDevices = devices;
            _isLoadingDevices = false;
          });

        } else {
          print('DEBUG: No document found with connectionId: $_connectionId');
          setState(() {
            _isLoadingDevices = false;
            _hasPairedDevices = false;
            _connectedDevices = [];
          });
        }
        return;
      }

      // Fallback to device-based query if connectionId is not available
      print('DEBUG: ConnectionId not available, trying device-based query');

      String deviceId = getCurrentDeviceId();
      print('DEBUG: Current device ID: $deviceId');

      if (deviceId.isEmpty) {
        print('DEBUG: Device ID is empty');
        setState(() {
          _isLoadingDevices = false;
          _hasPairedDevices = false;
          _connectedDevices = [];
        });
        return;
      }

      // First, let's try to find all documents and see what we have
      QuerySnapshot allDocs = await FirebaseFirestore.instance
          .collection('paired_devices')
          .get();

      print('DEBUG: Found ${allDocs.docs.length} paired_devices documents');

      for (var doc in allDocs.docs) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        print('DEBUG: Document ${doc.id}: ${data.keys.toList()}');

        // Check if this document contains our device
        // FIXED: Changed from 'playerDeviceInfo' to 'childDeviceInfo'
        if (data['childDeviceInfo'] != null) {
          Map<String, dynamic> childInfo = data['childDeviceInfo'];
          print('DEBUG: ChildDeviceInfo in ${doc.id}: $childInfo');

          // Check if this matches our device
          if (Platform.isAndroid &&
              childInfo['androidId'] == _deviceInfo['androidId'] &&
              childInfo['brand'] == _deviceInfo['brand'] &&
              childInfo['model'] == _deviceInfo['model']) {
            print('DEBUG: MATCH FOUND! Document ${doc.id} matches our Android device');
            // Process this document
            _processFoundPairing(doc);
            return;
          } else if (Platform.isIOS &&
              childInfo['identifierForVendor'] == _deviceInfo['identifierForVendor']) {
            print('DEBUG: MATCH FOUND! Document ${doc.id} matches our iOS device');
            // Process this document
            _processFoundPairing(doc);
            return;
          }
        }
      }

      print('DEBUG: No matching paired device found after checking all documents');
      setState(() {
        _isLoadingDevices = false;
        _hasPairedDevices = false;
        _connectedDevices = [];
      });

    } catch (e) {
      print('DEBUG: Error fetching paired devices: $e');
      setState(() {
        _isLoadingDevices = false;
        _hasPairedDevices = false;
        _connectedDevices = [];
      });
    }
    if (_connectionId != null && !_isEnhancedMonitoringActive) {
      await _startEnhancedMonitoring();
    }
  }

  void _processFoundPairing(DocumentSnapshot pairingDoc) {
    Map<String, dynamic> pairingData = pairingDoc.data() as Map<String, dynamic>;

    // Store the connection ID for later use
    _connectionId = pairingDoc.id;

    print('DEBUG: Processing found pairing: $pairingData');

    setState(() {
      _hasPairedDevices = true;
    });

    // Create connected device objects
    List<ConnectedDevice> devices = [];

    // Add parent device info
    if (pairingData['parentDeviceId'] != null) {
      String parentDeviceName = 'Parent Device';

      if (pairingData['parentDeviceInfo'] != null) {
        Map<String, dynamic> parentInfo = pairingData['parentDeviceInfo'];
        if (parentInfo['brand'] != null && parentInfo['model'] != null) {
          parentDeviceName = '${parentInfo['brand']} ${parentInfo['model']}';
        }
      }

      devices.add(ConnectedDevice(
        id: pairingData['parentDeviceId'],
        name: parentDeviceName,
        deviceType: 'Parent Device',
        status: 'Online',
        icon: Icons.smartphone,
        lastSeen: DateTime.now(),
      ));
    }

    setState(() {
      _connectedDevices = devices;
      _isLoadingDevices = false;
    });
  }

  void _onAddDevicePressed() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => QRScannerScreen(deviceInfo: _deviceInfo),
      ),
    );

    if (result != null) {
      print('Scanned data: $result');

      // Show loading dialog while pairing
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFFE8956C)),
              SizedBox(height: 16),
              Text('Pairing device...'),
            ],
          ),
        ),
      );

      try {
        // Add your device pairing logic here
        // After successful pairing, refresh the data
        await Future.delayed(Duration(seconds: 2)); // Simulate pairing process

        // Close loading dialog
        Navigator.of(context).pop();

        // Refresh paired devices
        await refreshAfterPairing();

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Device paired successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );

      } catch (e) {
        // Close loading dialog
        Navigator.of(context).pop();

        // Show error message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to pair device: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  List<TaskReward> _tasksAndRewards = [];
  bool _isLoadingTasks = false;

  Future<void> _fetchTasksAndRewards() async {
    if (!_hasPairedDevices || _connectionId == null) {
      setState(() {
        _tasksAndRewards = [];
        _isLoadingTasks = false;
      });
      return;
    }
    setState(() { _isLoadingTasks = true; });

    try {
      // Fetch tasks from parent-assigned collection
      final docSnap = await FirebaseFirestore.instance
          .collection('task_and_rewards')
          .doc(_connectionId)
          .get();

      if (!docSnap.exists || docSnap.data() == null) {
        setState(() {
          _tasksAndRewards = [];
          _isLoadingTasks = false;
        });
        return;
      }

      final data = docSnap.data() as Map<String, dynamic>;
      final tasks = (data['tasks'] as List?) ?? [];

      // Filter tasks for this player device only (optional, if needed)
      final String playerDeviceId = 'child_android_${getCurrentDeviceId()}';
      List<TaskReward> fetchedTasks = tasks
          .where((t) => t['childDeviceId'] == playerDeviceId)
          .map((t) => TaskReward(
        id: t['scheduleId'] ?? '',
        task: t['task'] ?? '',
        reward: '${t['reward']['points']} pts',
        status: t['reward']['status'] ?? 'Pending',
        isCompleted: t['reward']['status'] == 'completed',
        updatedAt: t['updatedAt'] != null
            ? (t['updatedAt'] as Timestamp).toDate()
            : null,
      ))
          .toList();

      setState(() {
        _tasksAndRewards = fetchedTasks;
        _isLoadingTasks = false;
      });
    } catch (e) {
      print('Error fetching parent tasks: $e');
      setState(() {
        _tasksAndRewards = [];
        _isLoadingTasks = false;
      });
    }
  }

  Future<int> getOrPickBonusDayOfWeek() async {
    final prefs = await SharedPreferences.getInstance();
    final key = getWeeklyBonusPrefsKey(DateTime.now());
    int? day = prefs.getInt("$key:day");
    if (day == null) {
      // Pick random day 0-6 (Sunday-Saturday)
      day = Random().nextInt(7);
      await prefs.setInt("$key:day", day);
      await prefs.setBool("$key:completed", false);
    }
    return day;
  }

  Future<bool> isBonusTaskCompletedThisWeek() async {
    final prefs = await SharedPreferences.getInstance();
    final key = getWeeklyBonusPrefsKey(DateTime.now());
    return prefs.getBool("$key:completed") ?? false;
  }

  Future<void> setBonusTaskCompletedThisWeek() async {
    final prefs = await SharedPreferences.getInstance();
    final key = getWeeklyBonusPrefsKey(DateTime.now());
    await prefs.setBool("$key:completed", true);
  }

  List<InstalledGame> _installedGames = [];
  bool _isLoadingGames = true;

  String _determineGameCategory(String appName, String packageName) {
    final Map<String, String> categoryKeywords = {
      'minecraft': 'Sandbox',
      'roblox': 'Social',
      'fortnite': 'Battle Royale',
      'pubg': 'Battle Royale',
      'free fire': 'Battle Royale',
      'call of duty': 'Action',
      'mobile legends': 'MOBA',
      'clash': 'Strategy',
      'chess': 'Strategy',
      'tower defense': 'Strategy',
      'candy crush': 'Puzzle',
      'puzzle': 'Puzzle',
      'pokemon': 'Adventure',
      'genshin': 'RPG',
      'honkai': 'RPG',
      'rpg': 'RPG',
      'racing': 'Racing',
      'asphalt': 'Racing',
      'need for speed': 'Racing',
      'fifa': 'Sports',
      'nba': 'Sports',
      'sports': 'Sports',
      'casino': 'Casino',
      'card': 'Card',
      'board': 'Board',
      'arcade': 'Arcade',
      'simulation': 'Simulation',
    };

    for (String keyword in categoryKeywords.keys) {
      if (appName.contains(keyword) || packageName.contains(keyword)) {
        return categoryKeywords[keyword]!;
      }
    }

    return 'Game';
  }

  IconData _determineFallbackIcon(String appName) {
    final Map<String, IconData> iconKeywords = {
      'minecraft': Icons.view_in_ar,
      'roblox': Icons.groups,
      'fortnite': Icons.sports_esports,
      'pubg': Icons.sports_esports,
      'call of duty': Icons.military_tech,
      'mobile legends': Icons.shield,
      'chess': Icons.extension,
      'clash': Icons.castle,
      'candy': Icons.cake,
      'pokemon': Icons.catching_pokemon,
      'racing': Icons.directions_car,
      'fifa': Icons.sports_soccer,
      'nba': Icons.sports_basketball,
      'rpg': Icons.auto_awesome,
      'strategy': Icons.psychology,
      'adventure': Icons.explore,
      'simulation': Icons.build,
      'casino': Icons.casino,
      'card': Icons.style,
      'board': Icons.grid_on,
      'arcade': Icons.videogame_asset,
    };

    for (String keyword in iconKeywords.keys) {
      if (appName.contains(keyword)) {
        return iconKeywords[keyword]!;
      }
    }

    return Icons.games;
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
                // Header Section
                _buildHeader(),

                // Main Content
                _buildMainContent(),
              ],
            ),
          ),
        ),
        bottomNavigationBar: _buildBottomNavigationBar(),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          CircleAvatar(
            radius: 25,
            backgroundColor: Color(0xFFE8956C),
            child: Image.asset(
              'assets/ictrllogo.png',
              height: 200,
              width: 200,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _isLoading
                      ? const SizedBox(
                    height: 20,
                    width: 100,
                    child: LinearProgressIndicator(
                      backgroundColor: Colors.white30,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
                    ),
                  )
                      : Text(
                    "Welcome, $_username!",
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                // Points and Star here!
                FutureBuilder<int>(
                  future: _fetchAccumulatedPoints(),
                  builder: (context, snapshot) {
                    final points = snapshot.data ?? 0;
                    return Row(
                      children: [
                        Icon(Icons.star, color: Colors.amber, size: 22),
                        SizedBox(width: 4),
                        Text(
                          "$points",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.amber,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return Expanded(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Show different content based on selected tab
            if (_selectedIndex == 2) ...[
              // Only one container/card for dashboard overview
              Card(
                margin: EdgeInsets.symmetric(vertical: 18, horizontal: 0),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                color: Colors.white.withOpacity(0.07),
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Column(
                    children: [
                      _playerMiniCard("Connected Device", Icons.devices, _connectedDevices.isNotEmpty ? _connectedDevices.first.name : "None"),
                      SizedBox(height: 14),
                      // --- BIG RECENT GAMEPLAY CARD ---
                      _dashboardCardContainer(
                        child: _buildRecentGameplaySection(),
                        minHeight: 120,
                      ),
                      SizedBox(height: 14),
                      _playerMiniCard("Game Schedule", Icons.schedule, _gameSchedules.isNotEmpty ? "${_gameSchedules.length}" : "None"),
                      SizedBox(height: 14),
                      _playerMiniCard("Tasks", Icons.task_alt, _tasksAndRewards.isNotEmpty ? "${_tasksAndRewards.where((t)=>!t.isCompleted).length}" : "None"),
                    ],
                  ),
                ),
              ),
              _buildWeeklyGamingReport()
              // If you want, below this you can show your larger components (like details or actions)
            ] else if (_selectedIndex == 0) ...[
              // Schedule - Show only schedule section
              _buildSectionHeader("Game Schedule", Icons.schedule, onArchiveTap: _archivedSchedules.isEmpty ? null : _showArchivedSchedulesModal,),
              const SizedBox(height: 15),
              _buildGameScheduleSection(),
            ] else if (_selectedIndex == 1) ...[
              // Tasks - Show only tasks section
              _buildSectionHeaderWithVoucher("Tasks & Rewards", Icons.task_alt),
              const SizedBox(height: 15),
              _buildTasksAndRewardsSection(),
            ] else if (_selectedIndex == 3) ...[
              // Games - Show only games section
              _buildSectionHeader("Installed Games", Icons.games),
              const SizedBox(height: 15),
              _buildInstalledGamesSection(),
            ] else if (_selectedIndex == 4) ...[
              // Settings - Show settings content
              _buildSectionHeader("Settings", Icons.settings),
              const SizedBox(height: 15),
              _buildSettingsSection(),
            ],


          ],
        ),
      ),
    );
  }

  Widget _playerMiniCard(String title, IconData icon, String value) {
    return Container(
      height: 80, // <-- Increase height to make each box bigger
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12), // More padding
      decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.12),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(0.18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 8,
              offset: Offset(2,2),
            ),
          ]
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, color: Color(0xFFE8956C), size: 32), // Bigger icon
          SizedBox(width: 18),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center, // Centers vertically
            children: [
              Text(title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 17, // Bigger text
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
              SizedBox(height: 6),
              Text(value ?? "",
                style: TextStyle(
                  fontSize: 15, // Bigger value
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dashboardCardContainer({required Widget child, double minHeight = 120}) {
    return Card(
      margin: EdgeInsets.symmetric(vertical: 18, horizontal: 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      color: Colors.white.withOpacity(0.07),
      child: Container(
        padding: EdgeInsets.all(20),
        width: double.infinity,
        constraints: BoxConstraints(maxWidth: 460, minHeight: minHeight), // tweak width for your layout
        child: child,
      ),
    );
  }

  Widget _buildSettingsSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Colors.white.withOpacity(0.2),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          _buildSettingsItem(
            icon: Icons.account_circle,
            title: "Account Settings",
            subtitle: "Manage your profile and preferences",
            onTap: () async {
              // Get current user from Firebase Auth
              final user = FirebaseAuth.instance.currentUser;

              // If not signed in, show error or redirect to login
              if (user == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("You must be signed in."), backgroundColor: Colors.red),
                );
                return;
              }

              // If you want to get the password, you cannot get it directly.
              // For password changes, you can send the user to a password reset flow.

              // Navigate and pass username, connectionId, and user.email
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PlayerAccountManagementScreen(
                    username: _username,
                    connectionId: _connectionId,
                    email: user.email,
                    // Do NOT pass password!
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFE8956C).withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                color: const Color(0xFFE8956C),
                size: 20,
              ),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios,
              color: Colors.white60,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNavigationBar() {
    return Container(
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
      child: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedItemColor: const Color(0xFFE8956C),
        unselectedItemColor: Colors.white60,
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(
            icon: Stack(
              children: [
                Icon(Icons.schedule),
                if (_hasNewScheduleNotification)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      padding: EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      constraints: BoxConstraints(
                        minWidth: 14,
                        minHeight: 14,
                      ),
                      child: Center(
                        child: Text(
                          '1',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            label: 'Schedule',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.task),
            label: 'Tasks',
          ),
          BottomNavigationBarItem(
            icon: Icon(
              Icons.dashboard, // You can use Icons.home or any other// Size is typically 24-32 for nav bars
            ),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.games),
            label: 'Games',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, {VoidCallback? onArchiveTap}) {
    return Row(
      children: [
        Icon(
          icon,
          color: const Color(0xFFE8956C),
          size: 24,
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const Spacer(),
        if (onArchiveTap != null)
          IconButton(
            icon: Icon(Icons.archive_outlined, color: Colors.orange, size: 22),
            onPressed: onArchiveTap,
            tooltip: "View Archived Schedules",
          ),
      ],
    );
  }

  Widget _buildSectionHeaderWithVoucher(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFFE8956C), size: 24),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        FutureBuilder<List<Voucher>>(
          future: _fetchVouchers(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(width: 24);
            }
            final vouchers = snapshot.data ?? [];
            if (vouchers.isEmpty) return const SizedBox(width: 0);

            return InkWell(
              onTap: () {
                showModalBottomSheet(
                  context: context,
                  backgroundColor: Color(0xFF252A3A),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  builder: (ctx) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: _buildVoucherInventorySection(),
                  ),
                );
              },
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Icon(Icons.card_giftcard, color: Colors.orange, size: 20),
                  Text(
                    "${vouchers.length}",
                    style: const TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  void _showArchivedSchedulesModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final maxHeight = MediaQuery.of(context).size.height * 0.7;
        return Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              children: [
                Text("Archived Schedules", style: TextStyle(fontSize: 18, color: Colors.orange)),
                SizedBox(height: 10),
                if (_archivedSchedules.isEmpty)
                  Text("No archived schedules", style: TextStyle(color: Colors.white60)),
                ..._archivedSchedules.map((schedule) => _buildArchivedScheduleCard(schedule)).toList(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildArchivedScheduleCard(GameSchedule schedule) {
    return Container(
      margin: EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.archive, color: Colors.orange, size: 28),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(schedule.gameName ?? "Unknown Game", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("${schedule.time} • ${schedule.duration}", style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              schedule.status.toUpperCase(),
              style: TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedDevicesSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Colors.white.withOpacity(0.2),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: _isLoadingDevices
          ? Column(
        children: [
          SizedBox(
            height: 20,
            child: LinearProgressIndicator(
              backgroundColor: Colors.white30,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
            ),
          ),
          const SizedBox(height: 10),
          const Text('Loading devices...', style: TextStyle(color: Colors.white70)),
        ],
      )
          : _buildDevicesContent(),
    );
  }

  Widget _buildDevicesContent() {
    if (!_hasPairedDevices) {
      // No paired_devices record found
      return Center(
        child: Column(
          children: [
            Icon(
              Icons.devices_other,
              size: 48,
              color: Colors.white.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No paired devices found',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Scan QR code to pair with a device',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _onAddDevicePressed,
              icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
              label: const Text(
                'Scan QR Code',
                style: TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8956C),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      );
    } else if (_connectedDevices.isEmpty) {
      // paired_devices record exists but no connected devices
      return Center(
        child: Column(
          children: [
            Icon(
              Icons.check_circle,
              size: 48,
              color: Colors.green.withOpacity(0.7),
            ),
            const SizedBox(height: 16),
            Text(
              'Device paired successfully!',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white.withOpacity(0.7),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'You can now access game schedules and tasks',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () {
                // Refresh the data
                _fetchPairedDevices();
              },
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text(
                'Refresh',
                style: TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8956C),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      );
    } else {
      // Show connected devices list
      return Column(
        children: [
          // Success message
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Device paired successfully',
                  style: TextStyle(
                    color: Colors.green,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // Device list
          ..._connectedDevices.map((device) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 15),
              child: Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8956C).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      device.icon,
                      color: const Color(0xFFE8956C),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          device.deviceType,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ],
      );
    }
  }

  Widget _buildGameScheduleSection() {
    // Check if user needs to add devices first
    if (!_hasPairedDevices || _connectedDevices.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: Colors.white.withOpacity(0.2),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.devices_other,
                size: 48,
                color: Colors.white.withOpacity(0.5),
              ),
              const SizedBox(height: 16),
              Text(
                'Connect a device first',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You need to pair a device before viewing game schedules',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.6),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _onAddDevicePressed,
                icon: const Icon(Icons.add, color: Colors.white),
                label: const Text(
                  'Add Device',
                  style: TextStyle(color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE8956C),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Loading state
    if (_isLoadingSchedules) {
      return Column(
        children: [
          SizedBox(
            height: 20,
            child: LinearProgressIndicator(
              backgroundColor: Colors.white30,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
            ),
          ),
          const SizedBox(height: 10),
          const Text('Loading game schedules...', style: TextStyle(color: Colors.white70)),
        ],
      );
    }

    // Error state
    if (_hasScheduleError) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: Colors.white.withOpacity(0.2),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: Colors.red.withOpacity(0.7),
              ),
              const SizedBox(height: 16),
              Text(
                'Connection issue',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Trying to reconnect...',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.6),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Empty state if no schedules
    if (_gameSchedules.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: Colors.white.withOpacity(0.2),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.schedule,
                size: 48,
                color: Colors.white.withOpacity(0.5),
              ),
              const SizedBox(height: 16),
              Text(
                'No game schedules yet',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Schedules will appear here automatically when your parent assigns them',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.6),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // Archive toggle button
    Widget archiveButton = _archivedSchedules.isNotEmpty
        ? Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        icon: Icon(_showArchivedSchedules ? Icons.expand_less : Icons.expand_more, color: Colors.orange),
        label: Text(
          _showArchivedSchedules ? "Hide Archives" : "Show Archives",
          style: TextStyle(color: Colors.orange),
        ),
        onPressed: () {
          setState(() {
            _showArchivedSchedules = !_showArchivedSchedules;
          });
        },
      ),
    )
        : SizedBox();

    // ACTIVE SCHEDULES ONLY
    List<GameSchedule> activeOnly = _gameSchedules.where((schedule) {
      final status = schedule.status.toLowerCase();
      return !["finished", "missed", "passed", "completed", "cancelled"].contains(status);
    }).toList();

    Widget scheduleList = Column(
      children: activeOnly.map((schedule) {
        return FutureBuilder<GameSchedulePermission>(
            future: _checkGamePermission(schedule.gameName ?? ''),
            builder: (context, snapshot) {
              final permission = snapshot.data ?? GameSchedulePermission(
                isAllowed: false,
                reason: 'Checking...',
                schedule: null,
                remainingTime: null,
              );
              InstalledGame? installedGame;
              try {
                installedGame = _installedGames.firstWhere(
                      (game) => game.name.toLowerCase() == (schedule.gameName?.toLowerCase() ?? ''),
                );
              } catch (e) {
                installedGame = null;
              }

              return Container(
                margin: const EdgeInsets.only(bottom: 15),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    color: permission.isAllowed
                        ? Colors.green.withOpacity(0.5)
                        : Colors.white.withOpacity(0.2),
                    width: permission.isAllowed ? 2 : 1,
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(15),
                    onTap: permission.isAllowed
                        ? () => _onGameScheduleTap(schedule)
                        : () => _showGameNotAllowedDialog(
                        schedule.gameName ?? 'Game',
                        permission.reason
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: permission.isAllowed
                                  ? const Color(0xFFE8956C).withOpacity(0.2)
                                  : Colors.grey.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(10),
                              border: permission.isAllowed
                                  ? Border.all(color: Colors.green, width: 1)
                                  : null,
                            ),
                            child: Stack(
                              children: [
                                Center(
                                  child: installedGame != null
                                      ? GameIconWidget(game: installedGame, size: 32)
                                      : Icon(
                                    permission.isAllowed
                                        ? Icons.sports_esports
                                        : Icons.schedule,
                                    color: permission.isAllowed
                                        ? const Color(0xFFE8956C)
                                        : Colors.grey,
                                    size: 24,
                                  ),
                                ),
                                if (permission.isAllowed)
                                  Positioned(
                                    top: 2,
                                    right: 2,
                                    child: Container(
                                      width: 12,
                                      height: 12,
                                      decoration: const BoxDecoration(
                                        color: Colors.green,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 15),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  schedule.gameName ?? 'Unknown Game',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: permission.isAllowed
                                        ? Colors.white
                                        : Colors.white.withOpacity(0.7),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "${schedule.time} • ${schedule.duration}",
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.white70,
                                  ),
                                ),
                                if (permission.remainingTime != null)
                                  Text(
                                    permission.isAllowed
                                        ? "⏱️ ${_formatDuration(permission.remainingTime!)} remaining"
                                        : "⏳ Available in ${_formatDuration(permission.remainingTime!)}",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: permission.isAllowed
                                          ? Colors.green.shade300
                                          : Colors.orange.shade300,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: permission.isAllowed
                                  ? Colors.green.withOpacity(0.2)
                                  : Colors.orange.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  permission.isAllowed
                                      ? Icons.play_circle_fill
                                      : Icons.check,
                                  size: 16,
                                  color: permission.isAllowed
                                      ? Colors.green
                                      : Colors.orange,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  permission.isAllowed ? "PLAY NOW" : "FINISHED",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: permission.isAllowed
                                        ? Colors.green
                                        : Colors.orange,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }
        );
      }).toList(),
    );

    // ARCHIVED list
    Widget archivedList = (_archivedSchedules.isNotEmpty && _showArchivedSchedules)
        ? Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(
          children: [
            Icon(Icons.archive, color: Colors.orange, size: 20),
            const SizedBox(width: 8),
            const Text(
              'Archived Schedules',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white70,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ..._archivedSchedules.map((schedule) {
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: Colors.orange.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.sports_esports, color: Colors.orange, size: 28),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          schedule.gameName ?? 'Unknown Game',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "${schedule.time} • ${schedule.duration}",
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.archive, size: 16, color: Colors.orange),
                        SizedBox(width: 4),
                        Text(
                          "ARCHIVED",
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ],
    )
        : SizedBox();

    return Column(
      children: [
        archiveButton,
        scheduleList,
        archivedList,
      ],
    );
  }

  Widget _buildRecentGameplaySection() {
    if (_isLoadingActiveSessions) {
      return _buildLoadingCard("Loading Recent Gameplay...");
    }

    // Only show ENDED card if it is not still active in _activeGameSessions
    List<Widget> sessionCards = [];

    // Helper: Check if recently ended session matches any active session
    bool isDuplicate = false;
    if (_isShowingEndedSession && _recentlyEndedSession != null) {
      isDuplicate = _activeGameSessions.any((active) =>
      active.packageName == _recentlyEndedSession!.packageName &&
          active.gameName == _recentlyEndedSession!.gameName
      );
      if (!isDuplicate) {
        sessionCards.add(_buildEndedSessionCard(_recentlyEndedSession!));
      }
    }

    // Only show LIVE cards for sessions not shown above
    for (var session in _activeGameSessions) {
      // Don't show if it's the same as the recently ended session
      if (_isShowingEndedSession && _recentlyEndedSession != null &&
          session.packageName == _recentlyEndedSession!.packageName &&
          session.gameName == _recentlyEndedSession!.gameName) {
        continue;
      }
      sessionCards.add(_buildActiveSessionCard(session));
    }

    if (sessionCards.isEmpty) {
      return _buildEmptyStateCard();
    }

    return Column(
      children: sessionCards.map((card) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: card,
        );
      }).toList(),
    );
  }

  Widget _buildEndedSessionCard(GameSession session) {
    // Find the matching InstalledGame
    InstalledGame? installedGame;
    try {
      installedGame = _installedGames.firstWhere(
            (game) => game.packageName == session.packageName,
      );
    } catch (e) {
      installedGame = null;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 15),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[800]?.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.grey[600]?.withOpacity(0.5) ?? Colors.grey,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icon
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey[700],
            ),
            child: Center(
              child: installedGame != null
                  ? GameIconWidget(game: installedGame, size: 32)
                  : Icon(Icons.games, color: Colors.white70, size: 24),
            ),
          ),
          const SizedBox(width: 12),

          // Text Section
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.gameName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.red.withOpacity(0.3)),
                      ),
                      child: const Text(
                        'ENDED',
                        style: TextStyle(
                          color: Colors.red,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Played for ${_formatPlayTime(session.playTime)}',
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Ended ${_formatTimeAgo(DateTime.now().difference(session.launchedAt.add(session.playTime ?? Duration.zero)))}',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // Duration chip (no Flexible/Expanded here)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _formatPlayTime(session.playTime),
              style: const TextStyle(
                color: Colors.blue,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeeklyGamingReport() {
    if (_connectionId == null) {
      return SizedBox.shrink();
    }
    final now = DateTime.now();
    final startOfWeek = DateTime(now.year, now.month, now.day - (now.weekday - 1)); // Monday

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('game_sessions')
          .doc(_connectionId)
          .collection('sessions')
          .where('isActive', isEqualTo: false)
          .where('endedAt', isGreaterThan: Timestamp.fromDate(startOfWeek))
          .snapshots(),
      builder: (context, snapshot) {
        Map<String, int> gameTotals = {};
        Map<String, String> gamePackages = {};
        if (snapshot.hasData) {
          for (var doc in snapshot.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final gameName = data['gameName'] ?? 'Unknown Game';
            final playTime = data['totalPlayTimeSeconds'] ?? 0;
            final packageName = data['packageName'] ?? "";
            gameTotals[gameName] = (gameTotals[gameName] ?? 0) + (playTime is int ? playTime : int.tryParse(playTime.toString()) ?? 0);
            gamePackages[gameName] = packageName;
          }
        }
        if (gameTotals.isEmpty) {
          return _dashboardCardContainer(
            minHeight: 120,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.videogame_asset, size: 38, color: Colors.grey),
                SizedBox(height: 12),
                Text("No gaming sessions this week.",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                SizedBox(height: 4),
                Text("Play a game to see your weekly report here!",
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          );
        }
        int totalSeconds = gameTotals.values.fold(0, (a, b) => a + b);
        return _dashboardCardContainer(
          minHeight: 160, // Make taller for more content if you wish
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Weekly Gaming Report', style: TextStyle(fontSize: 18, color: Colors.orange, fontWeight: FontWeight.bold)),
              SizedBox(height: 6),
              Text('Total Play Time: ${_formatDuration(Duration(seconds: totalSeconds))}',
                  style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
              SizedBox(height: 10),
              ...gameTotals.entries.map((entry) {
                final percent = (totalSeconds == 0) ? 0.0 : entry.value / totalSeconds;
                final packageName = gamePackages[entry.key] ?? "";
                InstalledGame? installedGame;
                try {
                  installedGame = _installedGames.firstWhere((game) => game.packageName == packageName);
                } catch (_) {}
                return Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    children: [
                      installedGame != null
                          ? GameIconWidget(game: installedGame, size: 34)
                          : Icon(Icons.videogame_asset, size: 34, color: Colors.orange),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(entry.key, style: TextStyle(color: Colors.white)),
                            LinearProgressIndicator(
                              value: percent,
                              minHeight: 10,
                              backgroundColor: Colors.grey[800],
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                            ),
                            Text('${_formatDuration(Duration(seconds: entry.value))}',
                                style: TextStyle(color: Colors.grey[400])),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ],
          ),
        );
      },
    );
  }

  String _formatPlayTime(Duration? duration) {
    if (duration == null) return '0m';

    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m';
    } else {
      return '${seconds}s';
    }
  }

  String _formatTimeAgo(Duration difference) {
    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'just now';
    }
  }

  Widget _buildActiveSessionCard(GameSession session) {
    // Hide stale sessions (no recent heartbeat) to prevent ghost LIVE tiles
    if (!session.isFresh) {
      // Option A: hide the card completely
      return const SizedBox.shrink();

      // Option B (alternative): show a dimmed "Reconnecting…" card instead of LIVE.
      // return _buildStaleSessionCard(session);
    }

    // Find the installed game for icon
    InstalledGame? installedGame;
    try {
      installedGame = _installedGames.firstWhere(
            (game) => game.packageName == session.packageName,
      );
    } catch (_) {
      installedGame = null;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 15),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Colors.blue.withOpacity(0.3),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withOpacity(0.1),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            // Game icon with live indicator
            Stack(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.blue.withOpacity(0.5),
                      width: 1,
                    ),
                  ),
                  child: Center(
                    child: installedGame != null
                        ? GameIconWidget(game: installedGame, size: 32)
                        : const Icon(Icons.sports_esports, color: Colors.blue, size: 24),
                  ),
                ),
                // Live indicator dot
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          session.gameName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      // LIVE badge only for fresh sessions
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.red.withOpacity(0.5)),
                        ),
                        child: const Text(
                          'LIVE',
                          style: TextStyle(
                            color: Colors.red,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Started ${_formatTimeAgo(DateTime.now().difference(session.launchedAt))}",
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white70,
                    ),
                  ),
                  // Real-time play duration: use currentPlayTime
                  StreamBuilder<Duration>(
                    stream: Stream.periodic(
                      const Duration(seconds: 1),
                          (_) => session.currentPlayTime,
                    ),
                    builder: (context, snapshot) {
                      final playTime = snapshot.data ?? session.currentPlayTime;
                      return Text(
                        "Playing for ${_formatPlayTime(playTime)}",
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.green.shade300,
                          fontWeight: FontWeight.w500,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingCard(String message) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Colors.white.withOpacity(0.2),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          SizedBox(
            height: 20,
            width: double.infinity,
            child: LinearProgressIndicator(
              backgroundColor: Colors.white30,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
            ),
          ),
          SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyStateCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Colors.white.withOpacity(0.2),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.gamepad,
              size: 48,
              color: Colors.white.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No active gameplay',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start playing a game to see it here',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withOpacity(0.6),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTasksAndRewardsSection() {
    return FutureBuilder<int>(
      future: _fetchAccumulatedPoints(),
      builder: (context, snapshot) {
        final points = snapshot.data ?? 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // First Card: Tasks only (no points/star row here anymore)
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: Colors.white.withOpacity(0.2),
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.all(20),
              child: _isLoadingTasks
                  ? Column(
                children: [
                  SizedBox(
                    height: 20,
                    child: LinearProgressIndicator(
                      backgroundColor: Colors.white30,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text('Loading tasks...', style: TextStyle(color: Colors.white70)),
                ],
              )
                  : _buildTasksContent(),
            ),
            SizedBox(height: 16),

            // Second Card: Redeem Rewards
            if (_selectedIndex == 1) // Show this only on Tasks tab!
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.all(20),
                child: _buildRewardsRedemptionSection(points),
              ),
          ],
        );
      },
    );
  }

  Widget _buildRewardsRedemptionSection(int currentPoints) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Icon(Icons.card_giftcard, color: Colors.orange, size: 24),
              SizedBox(width: 8),
              Text(
                "Redeem Rewards",
                style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
        ),
        ...availableRewards.map((reward) {
          bool canRedeem = currentPoints >= reward.cost;

          return Card(
            color: Colors.white.withOpacity(0.07),
            margin: EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Icon
                  CircleAvatar(
                    backgroundColor: reward.color,
                    child: Icon(reward.icon, color: Colors.white),
                  ),
                  SizedBox(width: 16),
                  // Reward details
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          reward.name,  // Example: "(15 Minutes)"
                          style: TextStyle(
                            color: reward.color,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            overflow: TextOverflow.ellipsis,
                          ),
                          maxLines: 1,
                        ),
                        SizedBox(height: 2),
                        Text(
                          reward.description,
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 12),
                  // Cost and Button (vertical)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.orange.withOpacity(0.3)),
                        ),
                        child: Text(
                          "${reward.cost} pts",
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.orange,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      SizedBox(height: 6),
                      SizedBox(
                        height: 28,
                        child: ElevatedButton(
                          onPressed: canRedeem ? () => _onRedeemRewardPressed(reward) : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: reward.color,
                            foregroundColor: Colors.white,
                            elevation: canRedeem ? 4 : 0,
                            shadowColor: canRedeem ? Colors.orangeAccent : Colors.transparent,
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                            minimumSize: Size(60, 28),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: Text(
                            "Redeem",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ],
    );
  }

  Widget _buildVoucherInventorySection() {
    return FutureBuilder<List<Voucher>>(
        future: _fetchVouchers(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return CircularProgressIndicator();
          final vouchers = snapshot.data!;
          if (vouchers.isEmpty) return Text("No vouchers.", style: TextStyle(color: Colors.white));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: vouchers.map((v) => Container(
              margin: EdgeInsets.symmetric(vertical: 6),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.13),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(v.name, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange, fontSize: 16)),
                        Text("${v.minutes} minutes", style: TextStyle(color: Colors.white, fontSize: 14)),
                      ],
                    ),
                  ),
                  Text(
                    v.isUsed ? "Used" : "Unused",
                    style: TextStyle(
                      color: v.isUsed ? Colors.grey : Colors.greenAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                ],
              ),
            )).toList(),
          );
        }
    );
  }

  Future<List<Voucher>> _fetchVouchers() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('redeemed_rewards')
        .doc(_connectionId)
        .collection('vouchers')
        .where('isUsed', isEqualTo: false)
        .get();

    return snapshot.docs.map((doc) => Voucher.fromFirestore(doc)).toList();
  }

  Future<void> unlockGameWithKey(String packageName) async {
    // Fetch allowed_games document for connectionId
    final docRef = FirebaseFirestore.instance
        .collection('allowed_games')
        .doc(_connectionId);

    final docSnap = await docRef.get();
    if (!docSnap.exists) return;

    final data = docSnap.data() as Map<String, dynamic>;
    final List<dynamic> allowedGames = data['allowedGames'] ?? [];

    // Find the game object
    for (var game in allowedGames) {
      if (game['packageName'] == packageName) {
        game['isGameAllowed'] = true;
        game['unlockByKey'] = true;
        game['unlockExpiry'] = Timestamp.fromDate(DateTime(
            DateTime.now().year, DateTime.now().month, DateTime.now().day + 1, 0, 0, 0
        )); // Next midnight
        game['updatedAt'] = Timestamp.now();
        break;
      }
    }
    await docRef.update({'allowedGames': allowedGames});
  }

  Future<void> resetExpiredUnlocks() async {
    final docRef = FirebaseFirestore.instance.collection('allowed_games').doc(_connectionId);
    final docSnap = await docRef.get();
    if (!docSnap.exists) return;

    final data = docSnap.data() as Map<String, dynamic>;
    final List<dynamic> allowedGames = data['allowedGames'] ?? [];
    final now = DateTime.now();

    bool updated = false;
    for (var game in allowedGames) {
      if (game['isGameAllowed'] == true && game['unlockByKey'] == true) {
        final expiry = (game['unlockExpiry'] as Timestamp?)?.toDate();
        if (expiry != null && now.isAfter(expiry)) {
          game['isGameAllowed'] = false;
          game['unlockByKey'] = false;
          game['unlockExpiry'] = null;
          updated = true;
        }
      }
    }
    if (updated) {
      await docRef.update({'allowedGames': allowedGames});
    }
  }

  void _showUnlockKeyTutorial() async {
    if (_hasShownUnlockTutorial) return; // Do not show again if already shown

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black87,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Icon(Icons.vpn_key, color: Colors.orange, size: 32),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                "Congratulations!",
                style: TextStyle(
                  color: Colors.orange,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.vpn_key, color: Colors.yellowAccent, size: 60),
            SizedBox(height: 16),
            Text(
              "You received a Game Unlock Key!\n\nUse this to unlock any blocked game for today.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            SizedBox(height: 18),
            Text(
              "Go to the Games tab and tap the 'Unlock Me' animation on a blocked game.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.orangeAccent, fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                _selectedIndex = 3; // Switch to Games tab
                _hasShownUnlockTutorial = true; // Mark tutorial as shown
              });
            },
            child: Text("Go to Games", style: TextStyle(color: Colors.yellowAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _onRedeemRewardPressed(RedeemableReward reward) async {
    if (_connectionId == null) return;
    int currentPoints = _currentPoints;
    if (currentPoints < reward.cost) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Not enough points to redeem this reward"), backgroundColor: Colors.red),
      );
      return;
    }

    // Show dialog to select game
    final selectedGame = await showDialog<InstalledGame>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text("Choose a game to unlock"),
        children: _installedGames.map((game) => SimpleDialogOption(
          child: Row(
            children: [
              GameIconWidget(game: game, size: 28),
              SizedBox(width: 12),
              Text(game.name, style: TextStyle(color: Colors.white)),
            ],
          ),
          onPressed: () => Navigator.pop(ctx, game),
        )).toList(),
      ),
    );

    if (selectedGame == null) return;

    // Unlock selected game for the reward duration
    await unlockGameWithKeyForDuration(selectedGame.packageName, reward.duration);

    await _deductPoints(reward.cost);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("${selectedGame.name} unlocked for ${reward.duration.inMinutes} minutes!"), backgroundColor: reward.color),
    );

    setState(() {});
  }

  Future<void> unlockGameWithKeyForDuration(String packageName, Duration duration) async {
    final docRef = FirebaseFirestore.instance
        .collection('allowed_games')
        .doc(_connectionId);

    final docSnap = await docRef.get();
    if (!docSnap.exists) return;

    final data = docSnap.data() as Map<String, dynamic>;
    final List<dynamic> allowedGames = data['allowedGames'] ?? [];

    final now = DateTime.now();
    final expiry = now.add(duration);

    for (var game in allowedGames) {
      if (game['packageName'] == packageName) {
        game['isGameAllowed'] = true;
        game['unlockByKey'] = true;
        game['unlockExpiry'] = Timestamp.fromDate(expiry);
        game['updatedAt'] = Timestamp.now();
        break;
      }
    }
    await docRef.update({'allowedGames': allowedGames});
  }

// Add a helper to check if the player currently has an unused unlock key
  Future<bool> _hasUnusedUnlockKey() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('redeemed_rewards')
        .doc(_connectionId)
        .collection('vouchers')
        .where('type', isEqualTo: 'unlock_game')
        .where('isUsed', isEqualTo: false)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  int _getMinutesForReward(RedeemableReward reward) {
    if (reward.id == "extra_playtime_15") return 15;
    if (reward.id == "extra_playtime_30") return 30;
    if (reward.id == "extra_playtime_1h") return 60;
    return 0;
  }

  Future<void> _deductPoints(int cost) async {
    final docRef = FirebaseFirestore.instance.collection('accumulated_points').doc(_connectionId);
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(docRef);
      int oldPoints = (snapshot.exists && snapshot.data()?['points'] != null)
          ? snapshot.data()!['points'] as int
          : 0;
      if (oldPoints < cost) throw Exception("Not enough points");
      transaction.set(docRef, {'points': oldPoints - cost}, SetOptions(merge: true));
    });
  }

  Future<void> _applyRewardToNextSchedule(RedeemableReward reward) async {
    if (_gameSchedules.isEmpty) return;

    // Pick the first schedule for simplicity (could prompt user for which one)
    GameSchedule schedule = _gameSchedules.first;

    int extraMinutes = _getMinutesForReward(reward);
    // You may need to get the original minutes from schedule.duration string
    int originalMinutes = int.tryParse(schedule.duration.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    int newMinutes = originalMinutes + extraMinutes;

    // Update the schedule in Firestore
    DocumentReference docRef = FirebaseFirestore.instance
        .collection('gaming_scheduled')
        .doc(_connectionId!);

    // Find and update the specific schedule inside the schedules array
    DocumentSnapshot doc = await docRef.get();
    if (doc.exists) {
      Map<String, dynamic>? data = doc.data() as Map<String, dynamic>?;
      if (data != null && data['schedules'] != null) {
        List schedulesArray = List.from(data['schedules']);
        for (var s in schedulesArray) {
          if (s['id'] == schedule.id) {
            s['durationMinutes'] = newMinutes;
            s['duration'] = "$newMinutes minutes";
            break;
          }
        }
        await docRef.update({'schedules': schedulesArray});
      }
    }
  }

  Future<int> _fetchAccumulatedPoints() async {
    if (_connectionId == null) return 0;
    final doc = await FirebaseFirestore.instance
        .collection('accumulated_points')
        .doc(_connectionId)
        .get();
    if (doc.exists && doc.data() != null && doc['points'] != null) {
      return doc['points'] as int;
    }
    return 0;
  }

  Future<void> _markTaskAsCompleted(TaskReward taskReward) async {
    if (_connectionId == null) return;

    final docRef = FirebaseFirestore.instance
        .collection('task_and_rewards')
        .doc(_connectionId);

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(docRef);
      if (!snapshot.exists || snapshot.data() == null) return;

      final data = snapshot.data() as Map<String, dynamic>;
      final List tasks = List.from(data['tasks'] ?? []);
      int index = tasks.indexWhere((t) =>
      (t['scheduleId'] == taskReward.id && taskReward.id.isNotEmpty) ||
          (t['task'] == taskReward.task && t['reward']['points'].toString() == taskReward.reward.replaceAll(' pts', ''))
      );

      if (index == -1) return;

      // ADD THIS DEBUG PRINT
      tasks[index]['reward']['status'] = 'verify';
      tasks[index]['reward']['completedAt'] = DateTime.now();
      print('[DEBUG] Current tasks[$index] BEFORE update: ${tasks[index]}');

      transaction.update(docRef, {
        'tasks': tasks,
      });
    });

    await _fetchTasksAndRewards();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Marked for review!"), backgroundColor: Colors.green),
    );
  }

  Future<void> _saveFailedAttemptToFirestore(String category) async {
    final today = DateTime.now();
    final dateKey = "${today.year}-${today.month}-${today.day}";
    await FirebaseFirestore.instance
        .collection('task_and_rewards')
        .doc(_connectionId)
        .set({
      dateKey: {
        "category": category,
        "attempted": true,
        "success": false,
        "timestamp": FieldValue.serverTimestamp(),
      }
    }, SetOptions(merge: true));
  }

  Future<void> _saveSuccessAttemptToFirestore(String category, String reward) async {
    final today = DateTime.now();
    final dateKey = "${today.year}-${today.month}-${today.day}";
    await FirebaseFirestore.instance
        .collection('task_and_rewards')
        .doc(_connectionId)
        .set({
      dateKey: {
        "category": category,
        "attempted": true,
        "success": true,
        "reward": reward,
        "timestamp": FieldValue.serverTimestamp(),
      }
    }, SetOptions(merge: true));
  }

  Widget _buildCategoryButton(String label, Color color, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(label, style: TextStyle(fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildTasksContent() {
    if (!_hasPairedDevices) {
      // No paired devices - show pairing requirement
      return Center(
        child: Column(
          children: [
            Icon(
              Icons.link_off,
              size: 48,
              color: Colors.white.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Device pairing required',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Please pair a device first to view tasks and rewards',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withOpacity(0.5),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _onAddDevicePressed,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text(
                'Pair Device',
                style: TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8956C),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      );
    } else if (_tasksAndRewards.isEmpty) {
      // No tasks assigned by parents yet
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.info_outline, color: Colors.orange, size: 48),
            SizedBox(height: 10),
            Text(
              "No tasks set by parents yet.",
              style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              "Tasks assigned by your parent will show up here. Please check back later.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.white70),
            ),
          ],
        ),
      );
    } else {
      // Show tasks and rewards (no bonus/random quiz)
      return Column(
        children: _tasksAndRewards.map((taskReward) {
          return DelayedTaskCard(
            taskReward: taskReward,
            onComplete: () => _markTaskAsCompleted(taskReward),
          );
        }).toList(),
      );
    }
  }

  Future<Map<String, int>> _getWeeklyGamePlayTotals() async {
    if (_connectionId == null) return {};
    final now = DateTime.now();
    final startOfWeek = DateTime(now.year, now.month, now.day - (now.weekday - 1)); // Monday

    QuerySnapshot sessionsSnap = await FirebaseFirestore.instance
        .collection('game_sessions')
        .doc(_connectionId)
        .collection('sessions')
        .where('isActive', isEqualTo: false)
        .where('endedAt', isGreaterThan: Timestamp.fromDate(startOfWeek))
        .get();

    Map<String, int> gameTotals = {};
    for (var doc in sessionsSnap.docs) {
      final data = doc.data() as Map<String, dynamic>;
      final gameName = data['gameName'] ?? 'Unknown Game';
      final playTime = data['totalPlayTimeSeconds'] ?? 0;
      gameTotals[gameName] = (gameTotals[gameName] ?? 0) + (playTime is int ? playTime : int.tryParse(playTime.toString()) ?? 0);
    }

    return gameTotals;
  }

  Widget _buildInstalledGamesSection() {
    if (_isLoadingGames) {
      return Column(
        children: [
          SizedBox(
            height: 20,
            child: LinearProgressIndicator(
              backgroundColor: Colors.white30,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE8956C)),
            ),
          ),
          const SizedBox(height: 10),
          const Text('Fetching Installed Games...', style: TextStyle(color: Colors.white70)),
        ],
      );
    }

    if (_installedGames.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: Colors.white.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: const Center(
          child: Text(
            'No games found on this device',
            style: TextStyle(
              fontSize: 16,
              color: Colors.white70,
            ),
          ),
        ),
      );
    }

    return FutureBuilder<bool>(
      future: _hasUnusedUnlockKey(),
      builder: (context, snapshot) {
        final hasUnlockKey = snapshot.data ?? false;

        return Column(
          children: _installedGames.map((game) {
            // Show unlock animation if blocked and has unlock key
            bool showUnlockButton = hasUnlockKey && !game.isAllowed;
            return Container(
              margin: const EdgeInsets.only(bottom: 15),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: Colors.white.withOpacity(0.2),
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: game.isAllowed
                          ? const Color(0xFFE8956C).withOpacity(0.2)
                          : Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: GameIconWidget(
                      game: game,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          game.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          "${game.category} • ${game.timeSpent}",
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showUnlockButton)
                    _UnlockMeAnimatedButton(
                      onUnlock: () async {
                        // Confirm unlock
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            title: Row(
                              children: [
                                Icon(Icons.vpn_key, color: Colors.orange, size: 28),
                                SizedBox(width: 10),
                                Text("Unlock Game?", style: TextStyle(color: Colors.orange)),
                              ],
                            ),
                            content: Text(
                              "Do you want to use your unlock key for \"${game.name}\"?\nThis game will be allowed until midnight.",
                              style: TextStyle(color: Colors.white),
                            ),
                            actions: [
                              TextButton(
                                child: Text("Cancel", style: TextStyle(color: Colors.grey)),
                                onPressed: () => Navigator.of(ctx).pop(false),
                              ),
                              TextButton(
                                child: Text("Unlock", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                                onPressed: () => Navigator.of(ctx).pop(true),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          await unlockGameWithKey(game.packageName);
                          // Mark voucher as used
                          final snap = await FirebaseFirestore.instance
                              .collection('redeemed_rewards')
                              .doc(_connectionId)
                              .collection('vouchers')
                              .where('type', isEqualTo: 'unlock_game')
                              .where('isUsed', isEqualTo: false)
                              .limit(1)
                              .get();
                          if (snap.docs.isNotEmpty) {
                            await snap.docs.first.reference.update({
                              'isUsed': true,
                              'unlockedGamePackageName': game.packageName,
                              'usedAt': Timestamp.now(),
                            });
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text("${game.name} is unlocked for today!"),
                              backgroundColor: Colors.green,
                            ),
                          );
                          setState(() {});
                        }
                      },
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: game.isAllowed
                            ? Colors.green.withOpacity(0.2)
                            : Colors.red.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        game.isAllowed ? "Allowed" : "Blocked",
                        style: TextStyle(
                          fontSize: 12,
                          color: game.isAllowed ? Colors.green : Colors.red,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Future<bool> _hasAttemptedBonusTaskToday(String category) async {
    final today = DateTime.now();
    final dateKey = "${today.year}-${today.month}-${today.day}";
    DocumentSnapshot doc = await FirebaseFirestore.instance
        .collection('task_and_rewards')
        .doc(_connectionId)
        .get();
    if (doc.exists && (doc.data() as Map<String, dynamic>)[dateKey] != null) {
      final data = (doc.data() as Map<String, dynamic>)[dateKey];
      return data['category'] == category && data['attempted'] == true;
    }
    return false;
  }

  @override
  void dispose() {
    if (_isEnhancedMonitoringActive) {
      // Don't stop completely, just mark as inactive in preferences
      MonitoringPreferences.saveMonitoringState(
        autoStart: true,
        connectionId: _connectionId ?? '',
        monitoredGames: [], // Will be reloaded on resume
      );
    }
    GameplayNotificationService.cancelAllNotifications();
    WidgetsBinding.instance.removeObserver(this);
    _gameSessionsListener?.cancel();
    _sessionUpdateTimer?.cancel();
    _sessionEndDelay?.cancel();

    // Cancel notifications and end active sessions
    GameplayNotificationService.cancelGameplayNotifications();
    _endActiveGameSession();
    _stopScheduleEnforcement();
    _scheduleEnforcementTimer?.cancel();
    _parentUnlockSubscription?.cancel();

    _scheduleRefreshTimer?.cancel();
    _scheduleStreamSubscription?.cancel();
    _stopBackgroundMonitoring();
    _gameStatusCheckTimer?.cancel();
    _allowedGamesStreamSubscription?.cancel();
    _tasksStreamSubscription?.cancel();
    _pointsStreamSubscription?.cancel();
    super.dispose();
  }

}

class ConnectedDevice {
  final String id;
  final String name;
  final String deviceType;
  final String status;
  final IconData icon;
  final DateTime lastSeen;

  ConnectedDevice({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.status,
    required this.icon,
    required this.lastSeen,
  });
}

class GameSchedule {
  final String time;
  final String duration;
  final String status;
  final String day;
  final String? id;
  final DateTime? dateTime;
  final String? gameName;  // Add game name
  final String? description;  // Add description

  GameSchedule({
    required this.time,
    required this.duration,
    required this.status,
    required this.day,
    this.id,
    this.dateTime,
    this.gameName,
    this.description,
  });

  // Factory constructor for parent dashboard data structure
  factory GameSchedule.fromParentData(Map<String, dynamic> data) {
    // Extract time information
    final startTime = data['startTime'] ?? '00:00';
    final endTime = data['endTime'] ?? '00:00';
    final timeDisplay = '$startTime - $endTime';

    // Extract duration
    final durationMinutes = data['durationMinutes'] ?? 0;
    final durationDisplay = '${durationMinutes} minutes';

    // Extract date and format day
    final scheduledDate = (data['scheduledDate'] as Timestamp?)?.toDate();
    final dayDisplay = scheduledDate != null
        ? _formatDay(scheduledDate)
        : 'Unknown';

    // Determine status based on schedule data
    final status = _determineStatus(data, scheduledDate);

    return GameSchedule(
      id: data['id']?.toString(),
      time: timeDisplay,
      duration: durationDisplay,
      status: status,
      day: dayDisplay,
      dateTime: scheduledDate,
      gameName: data['gameName'],
      description: data['description'],
    );
  }

  // Original factory constructor (keep for backward compatibility if needed)
  factory GameSchedule.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return GameSchedule(
      id: doc.id,
      time: data['time'] ?? '',
      duration: data['duration'] ?? '',
      status: data['status'] ?? 'Available',
      day: data['day'] ?? '',
      dateTime: (data['dateTime'] as Timestamp?)?.toDate(),
      gameName: data['gameName'],
      description: data['description'],
    );
  }

  // Helper method to format day from DateTime
  static String _formatDay(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final scheduleDate = DateTime(date.year, date.month, date.day);

    if (scheduleDate == today) {
      return 'Today';
    } else if (scheduleDate == today.add(const Duration(days: 1))) {
      return 'Tomorrow';
    } else {
      // Return day name (Monday, Tuesday, etc.)
      const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      return days[date.weekday - 1];
    }
  }

  // Helper method to determine status
  static String _determineStatus(Map<String, dynamic> data, DateTime? scheduledDate) {
    final status = data['status'] ?? 'scheduled';

    if (status == 'completed') return 'Completed';
    if (status == 'cancelled') return 'Cancelled';
    if (status == 'active') return 'Active';

    // For scheduled status, check if it's available based on time
    if (scheduledDate != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final scheduleDay = DateTime(scheduledDate.year, scheduledDate.month, scheduledDate.day);

      if (scheduleDay == today) {
        // Check if current time is within the scheduled time
        final startTime = data['startTime'] ?? '00:00';
        final endTime = data['endTime'] ?? '00:00';

        final startParts = startTime.split(':');
        final endParts = endTime.split(':');

        final startDateTime = DateTime(now.year, now.month, now.day,
            int.parse(startParts[0]), int.parse(startParts[1]));
        final endDateTime = DateTime(now.year, now.month, now.day,
            int.parse(endParts[0]), int.parse(endParts[1]));

        if (now.isAfter(startDateTime) && now.isBefore(endDateTime)) {
          return 'Available Now';
        } else if (now.isBefore(startDateTime)) {
          return 'Upcoming';
        } else {
          return 'Missed';
        }
      } else if (scheduleDay.isAfter(today)) {
        return 'Scheduled';
      } else {
        return 'Past';
      }
    }

    return 'Available';
  }

  // Method to convert to Firestore format (if needed for updates)
  Map<String, dynamic> toFirestore() {
    return {
      'time': time,
      'duration': duration,
      'status': status,
      'day': day,
      'dateTime': dateTime != null ? Timestamp.fromDate(dateTime!) : null,
      'gameName': gameName,
      'description': description,
    };
  }
}

class GameSchedulePermission {
  final bool isAllowed;
  final String reason;
  final GameSchedule? schedule;
  final Duration? remainingTime;

  GameSchedulePermission({
    required this.isAllowed,
    required this.reason,
    required this.schedule,
    required this.remainingTime,
  });
}

class GameSession {
  final String id;
  final String gameName;
  final String packageName;
  final DateTime launchedAt;
  final String childDeviceId;
  final Map<String, dynamic> deviceInfo;
  final bool isActive;
  final Duration? playTime;

  // NEW
  final DateTime? heartbeatAt;
  final DateTime? endedAt;
  final int? totalPlayTimeSeconds;

  GameSession({
    required this.id,
    required this.gameName,
    required this.packageName,
    required this.launchedAt,
    required this.childDeviceId,
    required this.deviceInfo,
    this.isActive = true,
    this.playTime,
    this.heartbeatAt,
    this.endedAt,
    this.totalPlayTimeSeconds,
  });

  factory GameSession.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final launchedAt = (data['launchedAt'] as Timestamp?)?.toDate() ?? DateTime.now();
    final heartbeat = (data['heartbeat'] as Timestamp?)?.toDate();
    final ended = (data['endedAt'] as Timestamp?)?.toDate();
    final totalSecs = (data['totalPlayTimeSeconds'] as num?)?.toInt();

    final bool active = data['isActive'] ?? true;

    return GameSession(
      id: doc.id,
      gameName: data['gameName'] ?? 'Unknown Game',
      packageName: data['packageName'] ?? '',
      launchedAt: launchedAt,
      childDeviceId: data['childDeviceId'] ?? '',
      deviceInfo: data['deviceInfo'] ?? {},
      isActive: active,
      // When inactive prefer stored total seconds; when active compute live
      playTime: active
          ? DateTime.now().difference(launchedAt)
          : (totalSecs != null ? Duration(seconds: totalSecs) : (ended != null ? ended.difference(launchedAt) : Duration.zero)),
      heartbeatAt: heartbeat,
      endedAt: ended,
      totalPlayTimeSeconds: totalSecs,
    );
  }

  // Always-current play time for display
  Duration get currentPlayTime {
    if (isActive) return DateTime.now().difference(launchedAt);
    if (totalPlayTimeSeconds != null) return Duration(seconds: totalPlayTimeSeconds!);
    if (endedAt != null) return endedAt!.difference(launchedAt);
    return playTime ?? Duration.zero;
  }

  // Consider the session "fresh" only if we saw a heartbeat recently
  bool get isFresh {
    if (!isActive) return false;
    if (heartbeatAt == null) return false;
    const maxSkew = Duration(seconds: 60); // tweak as you like (60–120s)
    return DateTime.now().difference(heartbeatAt!).abs() <= maxSkew;
  }

  String get formattedPlayTime {
    final duration = currentPlayTime;
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m ${seconds}s';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'gameName': gameName,
      'packageName': packageName,
      'launchedAt': launchedAt.toIso8601String(),
      'childDeviceId': childDeviceId,
      'deviceInfo': deviceInfo,
      'isActive': isActive,
      'playTimeSeconds': currentPlayTime.inSeconds,
      'heartbeat': heartbeatAt?.toIso8601String(),
      'endedAt': endedAt?.toIso8601String(),
      'totalPlayTimeSeconds': totalPlayTimeSeconds,
    };
  }
}

class GameSessionWidget extends StatefulWidget {
  final GameSession session;

  const GameSessionWidget({Key? key, required this.session}) : super(key: key);

  @override
  _GameSessionWidgetState createState() => _GameSessionWidgetState();
}

class _GameSessionWidgetState extends State<GameSessionWidget> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.session.isActive) {
      // Update UI every second for real-time display
      _timer = Timer.periodic(Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {}); // Trigger rebuild to show updated time
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(widget.session.gameName),
        subtitle: Text('Play time: ${widget.session.formattedPlayTime}'),
        trailing: widget.session.isActive
            ? Icon(Icons.play_circle, color: Colors.green)
            : Icon(Icons.stop_circle, color: Colors.red),
      ),
    );
  }
}

class GameplayNotificationService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  static bool _isInitialized = false;
  static Timer? _gameplayNotificationTimer;
  static Timer? _scheduleReminderTimer;
  static List<GameSchedule> _currentSchedules = [];

  static Future<void> initialize() async {
    if (_isInitialized) return;

    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings settings = InitializationSettings(android: androidSettings);

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        print('Notification tapped: ${response.payload}');
      },
    );

    // Create notification channels
    await _createNotificationChannels();

    // Request notification permissions for Android 13+
    if (Platform.isAndroid) {
      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    _isInitialized = true;
  }

  static Future<void> _createNotificationChannels() async {
    if (Platform.isAndroid) {
      final androidImplementation = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

      // Schedule reminder channel
      const scheduleChannel = AndroidNotificationChannel(
        'schedule_reminder_channel',
        'Schedule Reminders',
        description: 'Notifications for upcoming gaming schedules',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      );

      // Active schedule channel
      const activeScheduleChannel = AndroidNotificationChannel(
        'active_schedule_channel',
        'Active Schedule',
        description: 'Notifications for currently active gaming schedules',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );

      await androidImplementation?.createNotificationChannel(scheduleChannel);
      await androidImplementation?.createNotificationChannel(activeScheduleChannel);
    }
  }

  // NEW: Update schedules and handle notifications
  static Future<void> updateSchedules(List<GameSchedule> schedules) async {
    await initialize();

    _currentSchedules = schedules;

    // Cancel existing schedule reminders
    _scheduleReminderTimer?.cancel();

    // Show immediate schedule status
    await _showCurrentScheduleStatus();

    // Setup reminders for upcoming schedules
    await _scheduleUpcomingReminders();

    print('📅 Updated schedules: ${schedules.length} active schedules');
  }

  // NEW: Show current schedule status notification
  static Future<void> _showCurrentScheduleStatus() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Find today's schedules
    final todaySchedules = _currentSchedules.where((schedule) {
      if (schedule.dateTime == null) return false;
      final scheduleDay = DateTime(schedule.dateTime!.year, schedule.dateTime!.month, schedule.dateTime!.day);
      return scheduleDay == today;
    }).toList();

    if (todaySchedules.isEmpty) {
      await _showNoSchedulesToday();
      return;
    }

    // Find active schedule
    GameSchedule? activeSchedule;
    try {
      activeSchedule = todaySchedules.where((schedule) => schedule.status == 'Available Now').first;
    } catch (e) {
      activeSchedule = null;
    }

    if (activeSchedule != null) {
      await _showActiveScheduleNotification(activeSchedule);
    } else {
      // Find next upcoming schedule
      GameSchedule? upcomingSchedule;
      try {
        upcomingSchedule = todaySchedules.where((schedule) => schedule.status == 'Upcoming').first;
      } catch (e) {
        upcomingSchedule = null;
      }

      if (upcomingSchedule != null) {
        await _showUpcomingScheduleNotification(upcomingSchedule);
      } else {
        await _showScheduleSummary(todaySchedules);
      }
    }
  }

  // NEW: Show no schedules notification
  static Future<void> _showNoSchedulesToday() async {
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'schedule_reminder_channel',
      'Schedule Reminders',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFF9E9E9E),
      playSound: false,
      enableVibration: false,
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      2001,
      '📅 No Gaming Schedules Today',
      'You have no scheduled gaming sessions for today. Enjoy your free time!',
      details,
    );
  }

  // NEW: Show active schedule notification
  static Future<void> _showActiveScheduleNotification(GameSchedule schedule) async {
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'active_schedule_channel',
      'Active Schedule',
      importance: Importance.max,
      priority: Priority.max,
      ongoing: true,
      autoCancel: false,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFF4CAF50),
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      2002,
      '🎮 Gaming Time Active!',
      '${schedule.gameName ?? "Gaming"} is available now (${schedule.time})',
      details,
      payload: 'active_schedule:${schedule.gameName}',
    );
  }

  // NEW: Show upcoming schedule notification
  static Future<void> _showUpcomingScheduleNotification(GameSchedule schedule) async {
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'schedule_reminder_channel',
      'Schedule Reminders',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFE8956C),
      playSound: true,
      enableVibration: true,
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      2003,
      '⏰ Upcoming Gaming Session',
      '${schedule.gameName ?? "Gaming"} starts at ${schedule.time.split(' - ')[0]}',
      details,
      payload: 'upcoming_schedule:${schedule.gameName}',
    );
  }

  // NEW: Show schedule summary
  static Future<void> _showScheduleSummary(List<GameSchedule> todaySchedules) async {
    final totalSchedules = todaySchedules.length;
    final gameNames = todaySchedules.map((s) => s.gameName ?? 'Game').take(2).join(', ');

    String subtitle;
    if (totalSchedules == 1) {
      subtitle = 'You have 1 gaming session today: $gameNames';
    } else if (totalSchedules <= 2) {
      subtitle = 'You have $totalSchedules gaming sessions today: $gameNames';
    } else {
      subtitle = 'You have $totalSchedules gaming sessions today: $gameNames and ${totalSchedules - 2} more';
    }

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'schedule_reminder_channel',
      'Schedule Reminders',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFE8956C),
      playSound: false,
      enableVibration: false,
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      2004,
      '📅 Today\'s Gaming Schedule',
      subtitle,
      details,
    );
  }

  // NEW: Schedule upcoming reminders
  static Future<void> _scheduleUpcomingReminders() async {
    final now = DateTime.now();

    for (final schedule in _currentSchedules) {
      if (schedule.dateTime == null) continue;

      final scheduleDay = DateTime(schedule.dateTime!.year, schedule.dateTime!.month, schedule.dateTime!.day);
      final today = DateTime(now.year, now.month, now.day);

      // Only set reminders for today's schedules
      if (scheduleDay != today) continue;

      // Parse start time
      final timeParts = schedule.time.split(' - ');
      if (timeParts.isEmpty) continue;

      final startTime = _parseTime(timeParts[0]);
      if (startTime == null) continue;

      final startDateTime = DateTime(now.year, now.month, now.day, startTime.hour, startTime.minute);

      // Set reminder 15 minutes before
      final reminderTime = startDateTime.subtract(const Duration(minutes: 15));

      if (reminderTime.isAfter(now)) {
        final delay = reminderTime.difference(now);

        Timer(delay, () async {
          await _showScheduleReminder(schedule, 15);
        });

        print('⏰ Scheduled reminder for ${schedule.gameName} in ${delay.inMinutes} minutes');
      }

      // Set reminder 5 minutes before
      final lastReminderTime = startDateTime.subtract(const Duration(minutes: 5));

      if (lastReminderTime.isAfter(now)) {
        final delay = lastReminderTime.difference(now);

        Timer(delay, () async {
          await _showScheduleReminder(schedule, 5);
        });
      }
    }
  }

  // NEW: Show schedule reminder
  static Future<void> _showScheduleReminder(GameSchedule schedule, int minutesBefore) async {
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'schedule_reminder_channel',
      'Schedule Reminders',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFFF9800),
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 300, 200, 300]),
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      2005 + minutesBefore, // Unique ID for each reminder
      '⏰ Gaming Session Starting Soon',
      '${schedule.gameName ?? "Gaming"} starts in $minutesBefore minutes!',
      details,
      payload: 'reminder:${schedule.gameName}:$minutesBefore',
    );
  }

  // NEW: Helper method to parse time string
  static TimeOfDay? _parseTime(String timeString) {
    try {
      final parts = timeString.trim().split(':');
      if (parts.length != 2) return null;

      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);

      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

      return TimeOfDay(hour: hour, minute: minute);
    } catch (e) {
      return null;
    }
  }

  // NEW: Schedule change notification
  static Future<void> showScheduleUpdatedNotification(int newScheduleCount) async {
    await initialize();

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'schedule_reminder_channel',
      'Schedule Reminders',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFE8956C),
      playSound: false,
      enableVibration: true,
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    String message;
    if (newScheduleCount == 0) {
      message = 'All gaming schedules have been removed';
    } else if (newScheduleCount == 1) {
      message = 'You have 1 active gaming schedule';
    } else {
      message = 'You have $newScheduleCount active gaming schedules';
    }

    await _notifications.show(
      2006,
      '📅 Schedule Updated',
      message,
      details,
    );
  }

  // Existing methods remain the same...
  static Future<void> showGameStartNotification(String gameName, String packageName) async {
    await initialize();

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'gameplay_channel',
      'Gameplay Notifications',
      channelDescription: 'Notifications for active gameplay sessions',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: true,
      autoCancel: false,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFE8956C),
      playSound: true,
      enableVibration: true,
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      1001,
      '🎮 Now Playing',
      '$gameName is running',
      details,
      payload: packageName,
    );

    _startGameplayNotificationUpdates(gameName, packageName);
  }

  static void _startGameplayNotificationUpdates(String gameName, String packageName) {
    final startTime = DateTime.now();

    _gameplayNotificationTimer?.cancel();
    _gameplayNotificationTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final playTime = DateTime.now().difference(startTime);
      final formattedTime = _formatDuration(playTime);

      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'gameplay_channel',
        'Gameplay Notifications',
        channelDescription: 'Notifications for active gameplay sessions',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: true,
        autoCancel: false,
        showWhen: false,
        icon: '@mipmap/ic_launcher',
        color: Color(0xFFE8956C),
        playSound: false,
        enableVibration: false,
      );

      final NotificationDetails details = NotificationDetails(android: androidDetails);

      await _notifications.show(
        1001,
        '🎮 Playing: $gameName',
        'Play time: $formattedTime • Tap to view',
        details,
        payload: packageName,
      );
    });
  }

  // Enhanced time warning notification with more urgency
  static Future<void> showTimeWarningNotification(String message) async {
    await initialize();

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'time_warning_channel',
      'Time Warning',
      channelDescription: 'Notifications for time warnings during gameplay',
      importance: Importance.max,
      priority: Priority.max,
      ongoing: false,
      autoCancel: false,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFFF9800),
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
      visibility: NotificationVisibility.public,
      fullScreenIntent: true,
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      1003,
      '⏰ Gaming Time Warning',
      message,
      details,
    );

    print('📱 Time warning notification sent: $message');
  }

  // Enhanced time up notification with maximum urgency
  static Future<void> showGameTimeUpNotification(String gameName) async {
    await initialize();

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'screen_lock_channel',
      'Screen Lock Alert',
      channelDescription: 'Critical notifications when screen is locked',
      importance: Importance.max,
      priority: Priority.max,
      ongoing: true,
      autoCancel: false,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFF44336),
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 1000, 200, 1000, 200, 1000]),
      visibility: NotificationVisibility.public,
      fullScreenIntent: true,
      ledColor: Color(0xFFF44336),
      ledOnMs: 1000,
      ledOffMs: 500,
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      1004,
      'Schedule is Up!',
      'Gaming time for "$gameName" has ended. Game is blocked for now.',
      details,
    );

    await _notifications.cancel(1001);
    _gameplayNotificationTimer?.cancel();

    print('📱 Screen lock notification sent for: $gameName');
  }

  static Future<void> showGameEndNotification(String gameName, Duration playTime) async {
    await initialize();

    _gameplayNotificationTimer?.cancel();

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'gameplay_end_channel',
      'Gameplay Summary',
      channelDescription: 'Summary notifications when gameplay ends',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFF4CAF50),
      playSound: true,
      enableVibration: true,
    );

    final NotificationDetails details = NotificationDetails(android: androidDetails);

    final formattedTime = _formatDuration(playTime);

    await _notifications.show(
      1002,
      '🎯 Game Session Complete',
      '$gameName • Played for $formattedTime',
      details,
    );

    await _notifications.cancel(1001);
  }

  static Future<void> cancelGameplayNotifications() async {
    _gameplayNotificationTimer?.cancel();
    await _notifications.cancel(1001);
  }

  static Future<void> cancelTimeWarnings() async {
    try {
      await _notifications.cancel(1003);
      await _notifications.cancel(1004);
      await _notifications.cancel(1005);
      print('📱 Cancelled time-related notifications');
    } catch (e) {
      print('Error cancelling time notifications: $e');
    }
  }

  // NEW: Cancel schedule notifications
  static Future<void> cancelScheduleNotifications() async {
    try {
      _scheduleReminderTimer?.cancel();
      // Cancel all schedule-related notifications (2001-2020 range)
      for (int i = 2001; i <= 2020; i++) {
        await _notifications.cancel(i);
      }
      print('📱 Cancelled schedule notifications');
    } catch (e) {
      print('Error cancelling schedule notifications: $e');
    }
  }

  static Future<void> cancelAllNotifications() async {
    try {
      _gameplayNotificationTimer?.cancel();
      _scheduleReminderTimer?.cancel();
      await _notifications.cancelAll();
      print('📱 Cancelled all notifications');
    } catch (e) {
      print('Error cancelling all notifications: $e');
    }
  }

  static String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }
}

class ScreenLockOverlay extends StatefulWidget {
  final String gameName;
  final VoidCallback onUnlock;

  const ScreenLockOverlay({
    Key? key,
    required this.gameName,
    required this.onUnlock,
  }) : super(key: key);

  @override
  _ScreenLockOverlayState createState() => _ScreenLockOverlayState();
}

class _ScreenLockOverlayState extends State<ScreenLockOverlay>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _lockEnforcementTimer;
  bool _isLocked = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupSecureLock();
    _initializeAnimations();
    _startLockEnforcement();
  }

  void _setupSecureLock() {
    // Hide system UI (navigation bar, status bar)
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);

    // Set full screen
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _initializeAnimations() {
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(
      begin: 0.8,
      end: 1.2,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));
    _pulseController.repeat(reverse: true);
  }

  void _startLockEnforcement() {
    // Continuously ensure the lock screen stays active
    _lockEnforcementTimer = Timer.periodic(Duration(milliseconds: 500), (timer) {
      if (_isLocked && mounted) {
        // Keep bringing app to foreground if user tries to leave
        _bringAppToForeground();
        // Keep system UI hidden
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
      }
    });
  }

  Future<void> _bringAppToForeground() async {
    try {
      const platform = MethodChannel('com.ictrl.ictrl/screen_lock');
      await platform.invokeMethod('bringToForeground');
    } catch (e) {
      print('Error bringing app to foreground: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (_isLocked) {
      switch (state) {
        case AppLifecycleState.paused:
        case AppLifecycleState.inactive:
        case AppLifecycleState.hidden:
        // User tried to leave the app while locked - bring back immediately
          Future.delayed(Duration(milliseconds: 100), () {
            if (_isLocked && mounted) {
              _bringAppToForeground();
            }
          });
          break;
        case AppLifecycleState.resumed:
        // Ensure system UI stays hidden when returning
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
          break;
        case AppLifecycleState.detached:
          break;
      }
    }
  }

  void _handleUnlock() {
    _isLocked = false;
    _lockEnforcementTimer?.cancel();

    // Restore system UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    widget.onUnlock();
  }

  @override
  void dispose() {
    _isLocked = false;
    _lockEnforcementTimer?.cancel();
    _pulseController.dispose();
    WidgetsBinding.instance.removeObserver(this);

    // Restore system UI when disposing
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // Completely prevent back button
        print('🔒 Back button blocked - screen is locked');
        return false;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.red.withOpacity(0.8),
                Colors.black87,
                Colors.red.withOpacity(0.6),
              ],
            ),
          ),
          child: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _pulseAnimation.value,
                      child: Icon(
                        Icons.lock_outline,
                        size: 120,
                        color: Colors.white,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 40),
                Text(
                  'Gaming Time Ended',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Text(
                  'Your scheduled time for\n"${widget.gameName}" has ended',
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.white.withOpacity(0.9),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: Colors.white,
                        size: 30,
                      ),
                      const SizedBox(height: 15),
                      Text(
                        'Screen is locked',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Navigation is disabled until you acknowledge.\nReturn to your scheduled activities.',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withOpacity(0.8),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 60),
                ElevatedButton(
                  onPressed: _handleUnlock,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE8956C),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                    elevation: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline),
                      const SizedBox(width: 8),
                      Text(
                        'I Understand',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'This screen will stay locked until acknowledged',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withOpacity(0.6),
                    fontStyle: FontStyle.italic,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TaskReward {
  final String id; // Document ID for updates
  final String task;
  final String reward;
  final String status;
  final bool isCompleted;
  final DateTime? updatedAt;
  TaskReward({
    required this.id,
    required this.task,
    required this.reward,
    required this.status,
    required this.isCompleted,
    required this.updatedAt,
  });
}

class InstalledGame {
  final String name;
  final String category;
  final String timeSpent;
  final IconData icon;
  final bool isAllowed;
  final String packageName;
  final Uint8List? iconBytes;
  final String? iconBase64;
  final String? iconStorageUrl; // New field for Storage URL
  final GameIconData? iconData; // Enhanced icon data

  InstalledGame({
    required this.name,
    required this.category,
    required this.timeSpent,
    required this.icon,
    required this.isAllowed,
    required this.packageName,
    this.iconBytes,
    this.iconBase64,
    this.iconStorageUrl,
    this.iconData,
  });
}

class GamePermissionStatus {
  final bool isAllowed;
  final String reason;
  final bool hasParentalControls;
  final bool isConfiguredByParent;

  GamePermissionStatus({
    required this.isAllowed,
    required this.reason,
    required this.hasParentalControls,
    required this.isConfiguredByParent,
  });
}

class GameIconWidget extends StatefulWidget {
  final InstalledGame game;
  final double size;

  const GameIconWidget({
    Key? key,
    required this.game,
    this.size = 32,
  }) : super(key: key);

  @override
  _GameIconWidgetState createState() => _GameIconWidgetState();
}

class _GameIconWidgetState extends State<GameIconWidget> {
  GameIconData? _iconData;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  Future<void> _loadIcon() async {
    if (widget.game.iconData != null) {
      setState(() {
        _iconData = widget.game.iconData;
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      GameIconData iconData = await GameIconService.getGameIcon(
        widget.game.packageName,
        widget.game.name,
      );

      setState(() {
        _iconData = iconData;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading icon for ${widget.game.name}: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.game.isAllowed
              ? const Color(0xFFE8956C).withOpacity(0.3)
              : Colors.red.withOpacity(0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
            ),
          ),
        ),
      );
    }

    if (_iconData == null) {
      return _buildFallbackIcon();
    }

    switch (_iconData!.source) {
      case IconSource.localCache:
      case IconSource.app:
        if (_iconData!.iconBytes != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              _iconData!.iconBytes!,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => _buildFallbackIcon(),
            ),
          );
        }
        return _buildFallbackIcon();

      case IconSource.firebaseStorage:
        if (_iconData!.storageUrl != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: _iconData!.storageUrl!,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              errorWidget: (context, url, error) => _buildFallbackIcon(),
            ),
          );
        }
        return _buildFallbackIcon();

      case IconSource.fallback:
      default:
        return _buildFallbackIcon();
    }
  }

  Widget _buildFallbackIcon() {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.game.isAllowed
            ? const Color(0xFFE8956C).withOpacity(0.3)
            : Colors.red.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        _iconData?.fallbackIcon ?? widget.game.icon,
        color: widget.game.isAllowed ? const Color(0xFFE8956C) : Colors.red,
        size: widget.size * 0.6,
      ),
    );
  }

}

class GameIconData {
  final Uint8List? iconBytes;
  final String? storageUrl;
  final IconSource source;
  final IconData fallbackIcon;

  GameIconData({
    this.iconBytes,
    this.storageUrl,
    required this.source,
    required this.fallbackIcon,
  });
}

enum IconSource {
  localCache,
  app,
  firebaseStorage,
  fallback,
}

class GameIconService {
  static final FirebaseStorage _storage = FirebaseStorage.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Method 1: Improved local icon fetching with better error handling
  static Future<Uint8List?> fetchAppIcon(String packageName) async {
    try {
      // Get app info with icon
      List<AppInfo> apps = await InstalledApps.getInstalledApps(
        true, // include icons
        true, // include system apps to ensure we get the app
      );

      // Find the specific app
      AppInfo? targetApp = apps.firstWhere(
            (app) => app.packageName == packageName,
        orElse: () => throw Exception('App not found'),
      );

      if (targetApp.icon != null && targetApp.icon!.isNotEmpty) {
        print('✓ Successfully fetched icon for $packageName');
        return targetApp.icon!;
      }

      print('⚠ No icon data for $packageName');
      return null;
    } catch (e) {
      print('✗ Error fetching icon for $packageName: $e');
      return null;
    }
  }

  // Method 2: Upload icons to Firebase Storage and cache them
  static Future<String?> uploadIconToStorage(String packageName, Uint8List iconData) async {
    try {
      // Create a unique filename using package name hash
      String fileName = '${md5.convert(utf8.encode(packageName)).toString()}.png';
      Reference ref = _storage.ref().child('game_icons/$fileName');

      // Upload the icon
      UploadTask uploadTask = ref.putData(
        iconData,
        SettableMetadata(
          contentType: 'image/png',
          customMetadata: {
            'packageName': packageName,
            'uploadedAt': DateTime.now().toIso8601String(),
          },
        ),
      );

      TaskSnapshot snapshot = await uploadTask;
      String downloadUrl = await snapshot.ref.getDownloadURL();

      print('✓ Icon uploaded to Storage: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      print('✗ Error uploading icon: $e');
      return null;
    }
  }

  // Method 3: Local caching system
  static Future<String?> cacheIconLocally(String packageName, Uint8List iconData) async {
    try {
      Directory appDir = await getApplicationDocumentsDirectory();
      Directory iconsDir = Directory('${appDir.path}/cached_icons');

      if (!await iconsDir.exists()) {
        await iconsDir.create(recursive: true);
      }

      String fileName = '${md5.convert(utf8.encode(packageName)).toString()}.png';
      File iconFile = File('${iconsDir.path}/$fileName');

      await iconFile.writeAsBytes(iconData);

      print('✓ Icon cached locally: ${iconFile.path}');
      return iconFile.path;
    } catch (e) {
      print('✗ Error caching icon locally: $e');
      return null;
    }
  }

  // Method 4: Get cached icon from local storage
  static Future<Uint8List?> getCachedIcon(String packageName) async {
    try {
      Directory appDir = await getApplicationDocumentsDirectory();
      Directory iconsDir = Directory('${appDir.path}/cached_icons');

      String fileName = '${md5.convert(utf8.encode(packageName)).toString()}.png';
      File iconFile = File('${iconsDir.path}/$fileName');

      if (await iconFile.exists()) {
        return await iconFile.readAsBytes();
      }

      return null;
    } catch (e) {
      print('✗ Error reading cached icon: $e');
      return null;
    }
  }

  // Method 5: Complete icon management with fallback chain
  static Future<GameIconData> getGameIcon(String packageName, String appName) async {
    // 1. Try to get from local cache first
    Uint8List? cachedIcon = await getCachedIcon(packageName);
    if (cachedIcon != null) {
      return GameIconData(
        iconBytes: cachedIcon,
        source: IconSource.localCache,
        fallbackIcon: _determineFallbackIcon(appName),
      );
    }

    // 2. Try to fetch from the app directly
    Uint8List? appIcon = await fetchAppIcon(packageName);
    if (appIcon != null) {
      // Cache it locally for next time
      await cacheIconLocally(packageName, appIcon);

      return GameIconData(
        iconBytes: appIcon,
        source: IconSource.app,
        fallbackIcon: _determineFallbackIcon(appName),
      );
    }

    // 3. Try to get from Firestore/Storage (if you've uploaded them before)
    String? storageUrl = await getIconFromStorage(packageName);
    if (storageUrl != null) {
      return GameIconData(
        storageUrl: storageUrl,
        source: IconSource.firebaseStorage,
        fallbackIcon: _determineFallbackIcon(appName),
      );
    }

    // 4. Fallback to icon font
    return GameIconData(
      source: IconSource.fallback,
      fallbackIcon: _determineFallbackIcon(appName),
    );
  }

  // Get icon URL from Firebase Storage
  static Future<String?> getIconFromStorage(String packageName) async {
    try {
      String fileName = '${md5.convert(utf8.encode(packageName)).toString()}.png';
      Reference ref = _storage.ref().child('game_icons/$fileName');

      return await ref.getDownloadURL();
    } catch (e) {
      // Icon doesn't exist in storage
      return null;
    }
  }

  // Batch upload icons for multiple games
  static Future<void> batchUploadIcons(List<InstalledGame> games) async {
    for (InstalledGame game in games) {
      if (game.iconBytes != null) {
        String? storageUrl = await uploadIconToStorage(
            game.packageName,
            game.iconBytes!
        );

        if (storageUrl != null) {
          // Update game in Firestore with storage URL
          await updateGameIconUrl(game.packageName, storageUrl);
        }
      }
    }
  }

  // Update game icon URL in Firestore
  static Future<void> updateGameIconUrl(String packageName, String iconUrl) async {
    try {
      await _firestore
          .collection('game_icons')
          .doc(packageName)
          .set({
        'packageName': packageName,
        'iconUrl': iconUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating icon URL in Firestore: $e');
    }
  }

  static IconData _determineFallbackIcon(String appName) {
    final Map<String, IconData> iconKeywords = {
      'minecraft': Icons.view_in_ar,
      'roblox': Icons.groups,
      'fortnite': Icons.sports_esports,
      'pubg': Icons.sports_esports,
      'call of duty': Icons.military_tech,
      'mobile legends': Icons.shield,
      'chess': Icons.extension,
      'clash': Icons.castle,
      'candy': Icons.cake,
      'pokemon': Icons.catching_pokemon,
      'racing': Icons.directions_car,
      'fifa': Icons.sports_soccer,
      'nba': Icons.sports_basketball,
      'rpg': Icons.auto_awesome,
      'strategy': Icons.psychology,
      'adventure': Icons.explore,
      'simulation': Icons.build,
      'casino': Icons.casino,
      'card': Icons.style,
      'board': Icons.grid_on,
      'arcade': Icons.videogame_asset,
    };

    for (String keyword in iconKeywords.keys) {
      if (appName.toLowerCase().contains(keyword)) {
        return iconKeywords[keyword]!;
      }
    }

    return Icons.games;
  }
}

class BuiltInQuestion {
  final String question;
  final List<String> options;
  final int correctIndex;
  final String reward;
  final String category;

  BuiltInQuestion({
    required this.question,
    required this.options,
    required this.correctIndex,
    required this.reward,
    required this.category,
  });
}

final List<BuiltInQuestion> builtInQuestions = [
  BuiltInQuestion(
    question: "What is the powerhouse of the cell?",
    options: ["Nucleus", "Mitochondria", "Ribosome", "Chloroplast"],
    correctIndex: 1,
    reward: "Unlock a blocked game",
    category: "easy",
  ),
  BuiltInQuestion(
    question: "Who wrote 'Noli Me Tangere'?",
    options: ["Andres Bonifacio", "Emilio Aguinaldo", "Jose Rizal", "Manuel Quezon"],
    correctIndex: 2,
    reward: "Extra 10 minutes playtime",
    category: "easy",
  ),
  // Add more questions!
];

class QuizAttemptFlow extends StatefulWidget {
  final String category;
  final List<BuiltInQuestion> questionPool;
  final int initialAttemptsLeft;
  final Function(int attempts, List<BuiltInQuestion> remainingQuestions) onProgress;
  final Function(String reward) onSuccess;
  final Function() onFail;

  QuizAttemptFlow({
    required this.category,
    required this.questionPool,
    required this.initialAttemptsLeft,
    required this.onProgress,
    required this.onSuccess,
    required this.onFail,
  });

  @override
  _QuizAttemptFlowState createState() => _QuizAttemptFlowState();
}

class _QuizAttemptFlowState extends State<QuizAttemptFlow> {
  late List<BuiltInQuestion> questions;
  late int attemptsLeft;
  late BuiltInQuestion currentQuestion;
  int? selectedIndex;
  bool answered = false;
  bool correct = false;
  bool finished = false;
  String statusText = "";

  @override
  void initState() {
    super.initState();
    questions = List.from(widget.questionPool);
    attemptsLeft = widget.initialAttemptsLeft;
    currentQuestion = questions.removeAt(Random().nextInt(questions.length));
  }

  void _updateProgress() {
    widget.onProgress(attemptsLeft, questions);
  }

  // Call _updateProgress() whenever attempts/questions change:
  void attemptNextQuestion() {
    if (questions.isNotEmpty) {
      currentQuestion = questions.removeAt(Random().nextInt(questions.length));
      selectedIndex = null;
      answered = false;
      correct = false;
      statusText = "";
      setState(() {});
      _updateProgress();
    } else {
      finished = true;
      statusText = "No more questions available.";
      setState(() {});
      _updateProgress();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Bonus Question (${widget.category.toUpperCase()})",
            style: TextStyle(fontSize: 18, color: Colors.orange, fontWeight: FontWeight.bold)),
        SizedBox(height: 10),
        Text("Attempts left: $attemptsLeft", style: TextStyle(color: Colors.white70)),
        SizedBox(height: 10),
        Text(currentQuestion.question, style: TextStyle(fontSize: 16, color: Colors.white)),
        SizedBox(height: 15),
        ...List.generate(currentQuestion.options.length, (i) {
          return RadioListTile<int>(
            value: i,
            groupValue: selectedIndex,
            onChanged: answered || finished ? null : (val) => setState(() => selectedIndex = val),
            title: Text(currentQuestion.options[i], style: TextStyle(color: Colors.white)),
            activeColor: Colors.orange,
          );
        }),
        SizedBox(height: 10),
        if (!answered && !finished)
          ElevatedButton(
            onPressed: selectedIndex != null ? () async {
              setState(() {
                answered = true;
                correct = selectedIndex == currentQuestion.correctIndex;
                statusText = correct
                    ? "Correct! You earned: ${currentQuestion.reward}"
                    : "Incorrect!";
              });
              if (correct) {
                widget.onSuccess(currentQuestion.reward);
                finished = true;
                setState(() {});
              } else {
                attemptsLeft--;
                if (attemptsLeft > 0) {
                  await Future.delayed(Duration(seconds: 2));
                  attemptNextQuestion();
                } else {
                  await Future.delayed(Duration(seconds: 2));
                  statusText = "Incorrect. No reward earned. Try again tomorrow!";
                  finished = true;
                  widget.onFail();
                  setState(() {});
                }
              }
            } : null,
            child: Text("Submit"),
          ),
        SizedBox(height: 10),
        if (statusText.isNotEmpty)
          Text(
            statusText,
            style: TextStyle(
              color: correct ? Colors.green : Colors.red,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        if (finished)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text("Close", style: TextStyle(color: Colors.orange)),
          ),
      ],
    );
  }
}

class RedeemableReward {
  final String id;
  final String name;
  final int cost;
  final String description;
  final IconData icon;
  final Color color;
  final Duration duration;

  RedeemableReward({
    required this.id,
    required this.name,
    required this.cost,
    required this.description,
    required this.icon,
    required this.color,
    required this.duration,
  });
}

class Voucher {
  final String id;
  final String name;
  final int minutes;
  final DateTime createdAt;
  final bool isUsed;
  final String? appliedToScheduleId;

  Voucher({
    required this.id,
    required this.name,
    required this.minutes,
    required this.createdAt,
    required this.isUsed,
    this.appliedToScheduleId,
  });

  factory Voucher.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Voucher(
      id: data['id'] ?? doc.id,
      name: data['name'] ?? '',
      minutes: data['minutes'] ?? 0,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isUsed: data['isUsed'] ?? false,
      appliedToScheduleId: data['appliedToScheduleId'],
    );
  }
}

class TaskCard extends StatefulWidget {
  final Map<String, dynamic> taskData;
  TaskCard({required this.taskData});

  @override
  _TaskCardState createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  late DateTime updatedAt;
  Timer? _timer;
  Duration timeLeft = Duration.zero;

  @override
  void initState() {
    super.initState();
    // Firestore Timestamp to Dart DateTime
    updatedAt = (widget.taskData['updatedAt'] as Timestamp).toDate();
    _updateTimeLeft();
    _timer = Timer.periodic(Duration(seconds: 1), (timer) {
      _updateTimeLeft();
    });
  }

  void _updateTimeLeft() {
    final now = DateTime.now();
    final diff = now.difference(updatedAt);
    setState(() {
      timeLeft = Duration(minutes: 3) - diff;
    });
    if (timeLeft.isNegative && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canComplete = timeLeft.isNegative;
    return Card(
      child: Column(
        children: [
          Text(widget.taskData['task']),
          Text("Reward: ${widget.taskData['reward']['points']} pts"),
          if (!canComplete)
            Text("Available in ${timeLeft.inMinutes}:${(timeLeft.inSeconds % 60).toString().padLeft(2, '0')}"),
          if (canComplete)
            ElevatedButton(
              onPressed: () {/* mark as complete */},
              child: Text("Complete"),
            ),
        ],
      ),
    );
  }
}

class DelayedTaskCard extends StatefulWidget {
  final TaskReward taskReward;
  final VoidCallback onComplete;

  const DelayedTaskCard({
    Key? key,
    required this.taskReward,
    required this.onComplete,
  }) : super(key: key);

  @override
  _DelayedTaskCardState createState() => _DelayedTaskCardState();
}

class _DelayedTaskCardState extends State<DelayedTaskCard> {
  late DateTime updatedAt;
  Timer? _timer;
  Duration timeLeft = Duration.zero;

  @override
  void initState() {
    super.initState();
    // If for some reason updatedAt is null, fallback to now
    updatedAt = widget.taskReward.updatedAt ?? DateTime.now();
    _updateTimeLeft();
    _timer = Timer.periodic(Duration(seconds: 1), (timer) {
      _updateTimeLeft();
    });
  }

  void _updateTimeLeft() {
    final now = DateTime.now();
    final diff = now.difference(updatedAt);
    setState(() {
      timeLeft = Duration(minutes: 3) - diff;
    });
    if (timeLeft.isNegative && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canComplete = timeLeft.isNegative;
    final isWaitingApproval = widget.taskReward.status == 'verify';
    final isGranted = widget.taskReward.status == 'granted';

    return Card(
      margin: const EdgeInsets.only(bottom: 15),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.task_alt,
              color: isGranted
                  ? Colors.green
                  : (isWaitingApproval ? Colors.orange : (canComplete ? Colors.green : Colors.orange)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.taskReward.task, style: TextStyle(fontWeight: FontWeight.bold)),
                  Text("Reward: ${widget.taskReward.reward}"),
                  if (isGranted)
                    Text(
                      "🎉 Congrats! This task is verified. You earned ${widget.taskReward.reward}.",
                      style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                    ),
                  if (isWaitingApproval)
                    Text(
                      "Waiting for parent's approval...",
                      style: TextStyle(color: Colors.orange, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  if (!canComplete && !isWaitingApproval && !isGranted)
                    Text(
                      "Available in ${timeLeft.inMinutes}:${(timeLeft.inSeconds % 60).toString().padLeft(2, '0')}",
                      style: TextStyle(color: Colors.orange, fontSize: 13),
                    ),
                ],
              ),
            ),
            if (canComplete && !isWaitingApproval && !isGranted)
              ElevatedButton(
                onPressed: widget.onComplete,
                child: Text("Complete"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              ),
          ],
        ),
      ),
    );
  }
}

class _UnlockMeAnimatedButton extends StatefulWidget {
  final VoidCallback onUnlock;
  const _UnlockMeAnimatedButton({required this.onUnlock});

  @override
  State<_UnlockMeAnimatedButton> createState() => _UnlockMeAnimatedButtonState();
}

class _UnlockMeAnimatedButtonState extends State<_UnlockMeAnimatedButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<Color?> _colorAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: Duration(seconds: 1))..repeat(reverse: true);
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.15).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _colorAnim = ColorTween(begin: Colors.orange, end: Colors.yellowAccent).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (ctx, child) => Transform.scale(
        scale: _scaleAnim.value,
        child: ElevatedButton.icon(
          icon: Icon(Icons.vpn_key, color: _colorAnim.value),
          label: Text("Unlock Me", style: TextStyle(color: _colorAnim.value, fontWeight: FontWeight.bold)),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.black,
            foregroundColor: _colorAnim.value,
            elevation: 8,
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            side: BorderSide(color: _colorAnim.value ?? Colors.orange, width: 2),
          ),
          onPressed: widget.onUnlock,
        ),
      ),
    );
  }

}
