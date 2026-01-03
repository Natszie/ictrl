import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'parentdevice.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:async';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class ParentDashboard extends StatefulWidget {
  const ParentDashboard({Key? key}) : super(key: key);

  @override
  State<ParentDashboard> createState() => _ParentDashboardState();

}

class _ParentDashboardState extends State<ParentDashboard> {
  int _selectedIndex = 2;
  List<Map<String, dynamic>> _children = [];
  bool _isLoading = true;
  String? _connectionId = '';
  String _deviceId = '';
  Map<String, dynamic> _deviceInfo = {};
  final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();

  List<Map<String, dynamic>> _pairedDevices = [];

  List<Map<String, dynamic>> _gamingSchedules = [];

  List<Map<String, dynamic>>? _schedules = [];

  StreamSubscription<DocumentSnapshot>? _gamingSchedulesSubscription;
  Timer? _scheduleTimer;
  DateTime _currentTime = DateTime.now();
  static const int MAX_SCHEDULES_PER_CONNECTION = 3;

  String _selectedActivityFilter = 'today'; // or 'week', 'month'

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  DateTime _startOfWeek(DateTime now) =>
      now.subtract(Duration(days: now.weekday - 1)); // Monday

  DateTime _endOfWeek(DateTime now) =>
      _startOfWeek(now).add(Duration(days: 6)); // Sunday

  static const int PAUSE_ESTIMATED_SECONDS = 600;

  @override
  void initState() {
    print('🚀 InitState called');
    super.initState();

    // Initialize in the correct order
    _initializeAndLoadDevices().then((_) async {
      print('✅ Devices initialized, now setting up schedules...');
      // Now that _deviceId is set, initialize FCM and save the token
      if (_deviceId.isNotEmpty) {
        initializeFCM(_deviceId);
      }
      await _loadPairedDevices();
      await _loadGamingSchedules();
      await _setupGamingSchedulesStream();
      await _autoUpdateScheduleStatuses(); // <-- Ensure this runs immediately
      _startScheduleTimer();
    });
  }

  @override
  void dispose() {
    // Cancel subscriptions first
    _gamingSchedulesSubscription?.cancel();
    _gamingSchedulesSubscription = null;

    _scheduleTimer?.cancel();
    _scheduleTimer = null;

    // Then call super.dispose()
    super.dispose();
  }

  Future<void> _initializeAndLoadDevices() async {
    await _getDeviceId();
    await _loadPairedDevices();
  }

  Future<void> _loadPairedDevices() async {
    try {
      // Use the current device's ID as parent identifier
      if (_deviceId.isEmpty) {
        await _getDeviceId();
      }

      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('paired_devices')
          .where('parentDeviceId', isEqualTo: _deviceId)
          .get();

      setState(() {
        _pairedDevices = snapshot.docs
            .map((doc) {
          final data = doc.data() as Map<String, dynamic>?;
          if (data == null) return null;

          return {
            'id': doc.id,
            'docData': data,
            // Extract child device info for easier access
            'childDeviceId': data['childDeviceId'],
            'childDeviceInfo': data['childDeviceInfo'],
            'connectionStatus': data['connectionStatus'] ?? 'offline',
            'lastConnected': data['lastConnected'],
            'pairedAt': data['pairedAt'],
          };
        })
            .where((device) => device != null)
            .cast<Map<String, dynamic>>()
            .toList();

        // Set connection ID - use the first paired device's document ID
        // or the one that's currently online/active
        if (_pairedDevices.isNotEmpty) {
          // Option 1: Use the first paired device
          _connectionId = _pairedDevices.first['id'];

          // Option 2: Use the first online device (if you want to be more specific)
          // final onlineDevice = _pairedDevices.firstWhere(
          //   (device) => device['connectionStatus'] == 'online',
          //   orElse: () => _pairedDevices.first,
          // );
          // _connectionId = onlineDevice['id'];
        } else {
          _connectionId = ''; // No paired devices
        }

        _isLoading = false;
      });

      print('Connection ID set to: $_connectionId'); // Debug log
    } catch (e) {
      print('Error loading paired devices: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<Map<String, dynamic>> _getDeviceId() async {
    try {
      String deviceId = '';
      Map<String, dynamic> deviceInfo = {};

      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await _deviceInfoPlugin.androidInfo;
        deviceId = androidInfo.id;

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

      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await _deviceInfoPlugin.iosInfo;
        deviceId = iosInfo.identifierForVendor ?? 'ios_${DateTime.now().millisecondsSinceEpoch}';

        deviceInfo = {
          'platform': 'iOS',
          'name': iosInfo.name,
          'model': iosInfo.model,
          'systemName': iosInfo.systemName,
          'systemVersion': iosInfo.systemVersion,
          'identifierForVendor': iosInfo.identifierForVendor,
          'deviceName': '${iosInfo.name}',
        };

      } else {
        deviceId = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
        deviceInfo = {
          'platform': 'Unknown',
          'deviceName': 'Unknown Device',
          'model': 'Unknown',
        };
      }

      setState(() {
        _deviceId = 'parent_$deviceId';
        _deviceInfo = deviceInfo;
      });

      return {
        'deviceId': 'parent_$deviceId',
        'deviceInfo': deviceInfo,
      };

    } catch (e) {
      print('Error getting device info: $e');
      final fallbackData = {
        'deviceId': 'parent_${DateTime.now().millisecondsSinceEpoch}',
        'deviceInfo': {
          'platform': 'Unknown',
          'deviceName': 'Unknown Device',
          'model': 'Unknown',
        }
      };

      setState(() {
        _deviceId = fallbackData['deviceId'] as String;
        _deviceInfo = fallbackData['deviceInfo'] as Map<String, dynamic>;
      });

      return fallbackData;
    }
  }

  Future<bool> addGamingSchedule({
    required String childDeviceId,
    required String gameName,
    required String packageName,
    required DateTime scheduledDate,
    required TimeOfDay startTime,
    required TimeOfDay endTime,
    required int durationMinutes,
    List<Map<String, dynamic>>? tasks,
    bool isRecurring = false,
    List<int>? recurringDays,
  }) async {
    try {
      // Ensure we have a connectionId
      if (_connectionId == null || _connectionId!.isEmpty) {
        print('Error: connectionId is required - current value: "$_connectionId"');
        return false;
      }

      // 🆕 AUTO-CLEANUP: Remove expired schedules first
      await _cleanupExpiredSchedules();

      // Check current schedules count after cleanup
      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .get();

      List<dynamic> existingSchedules = [];
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>?;
        existingSchedules = data?['schedules'] ?? [];
      }

      // Check if we can add more schedules
      final activeCount = existingSchedules.where((s) {
        final status = (s['status'] ?? '').toString().toLowerCase();
        return status != 'completed' && status != 'cancelled';
      }).length;

      if (activeCount >= MAX_SCHEDULES_PER_CONNECTION) {
        print('Cannot add more schedules. Maximum of $MAX_SCHEDULES_PER_CONNECTION active schedules allowed per connection.');
        return false;
      }

      DateTime now = DateTime.now();
      Timestamp currentTimestamp = Timestamp.fromDate(now);

      // Create new schedule object
      Map<String, dynamic> newSchedule = {
        'id': now.millisecondsSinceEpoch.toString(),
        'childDeviceId': childDeviceId,
        'gameName': gameName,
        'packageName': packageName,
        'scheduledDate': Timestamp.fromDate(scheduledDate),
        'startTime': '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}',
        'endTime': '${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}',
        'durationMinutes': durationMinutes,
        'isActive': true,
        'isRecurring': isRecurring,
        'recurringDays': recurringDays ?? [],
        'createdAt': currentTimestamp,
        'updatedAt': currentTimestamp,
        'status': 'scheduled',
      };

      existingSchedules.add(newSchedule);

      Map<String, dynamic> documentData = {
        'parentDeviceId': _deviceId,
        'connectionId': _connectionId,
        'schedules': existingSchedules,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (!doc.exists) {
        documentData['createdAt'] = FieldValue.serverTimestamp();
      }

      await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .set(documentData, SetOptions(merge: true));

      // --- ADDITION: Save each task in tasks_and_rewards ---
      if (tasks != null && tasks.isNotEmpty) {
        DocumentReference docRef = FirebaseFirestore.instance
            .collection('task_and_rewards')
            .doc(_connectionId);

        // Get the existing tasks array (if any)
        DocumentSnapshot docSnap = await docRef.get();
        List<dynamic> tasksArray = [];
        if (docSnap.exists && docSnap.data() != null && (docSnap.data() as Map<String, dynamic>)['tasks'] != null) {
          tasksArray = List.from((docSnap.data() as Map<String, dynamic>)['tasks']);
        }

        // Add new tasks to the array
        for (var task in tasks) {
          var newTask = {
            'task': task['name'], // Task name
            'reward': {
              'points': task['points'],
              'status': 'pending',
            },
            'childDeviceId': childDeviceId,
            'parentDeviceId': _deviceId,
            'createdAt': currentTimestamp,
            'updatedAt': currentTimestamp,
          };

          // Only add these if you want them and they are not null
          if (newSchedule['id'] != null) newTask['scheduleId'] = newSchedule['id'];
          if (scheduledDate != null) newTask['scheduledDate'] = Timestamp.fromDate(scheduledDate);

          tasksArray.add(newTask);
        }

        // Save back to Firestore
        await docRef.set({
          'tasks': tasksArray,
          'parentDeviceId': _deviceId,
          'connectionId': _connectionId,
          'updatedAt': currentTimestamp,
        }, SetOptions(merge: true));
      }
      // --- END ADDITION ---

      bool allowedGameUpdated = await _updateAllowedGamesFromSchedules();

      if (!allowedGameUpdated) {
        print('Warning: Failed to update allowed games, but schedule was created successfully');
      }

      print('Gaming schedule added successfully to connectionId: $_connectionId');
      print('Game "$gameName" has been added to allowed games');

      return true;
    } catch (e) {
      print('Error adding gaming schedule: $e');
      return false;
    }
  }

  Future<void> _cleanupExpiredSchedules() async {
    try {
      if (_connectionId == null || _connectionId!.isEmpty) {
        return;
      }

      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .get();

      if (!doc.exists) return;

      final data = doc.data() as Map<String, dynamic>?;
      if (data == null || data['schedules'] == null) return;

      List<dynamic> schedules = List.from(data['schedules']);
      DateTime now = DateTime.now();
      bool anyChanges = false;

      for (var schedule in schedules) {
        if (schedule['scheduledDate'] == null || schedule['endTime'] == null) continue;

        // Only non-recurring schedules
        if (schedule['isRecurring'] == true) continue;

        // Get status and isActive
        final status = (schedule['status'] ?? '').toLowerCase();
        final isActive = schedule['isActive'] == true;

        // Parse endDateTime
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
          // If the schedule is still marked as active or not completed, mark it as completed/inactive
          if (status != 'completed' || isActive) {
            schedule['status'] = 'completed';
            schedule['isActive'] = false;
            schedule['updatedAt'] = Timestamp.fromDate(now);
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
      await _updateAllowedGamesFromSchedules();
    } catch (e) {
      print('❌ Error during cleanup: $e');
    }
  }

  Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
    print("FCM Background message: ${message.messageId}");
    // Optionally show a local notification here
  }

  void initializeFCM(String parentDeviceId) async {
    await FirebaseMessaging.instance.requestPermission();

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Foreground notifications
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('FCM Foreground message: ${message.notification?.title}');
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

    // Get and save the token!
    String? token = await FirebaseMessaging.instance.getToken();
    print('FCM Token: $token');

    // Save to Firestore so your backend can use it
    if (token != null) {
      await FirebaseFirestore.instance.collection('parent_tokens').doc(parentDeviceId).set({
        'token': token,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> _setupGamingSchedulesStream() async {
    try {
      if (_deviceId.isEmpty) {
        await _getDeviceId();
      }

      if (_connectionId == null || _connectionId!.isEmpty) {
        print('❌ ConnectionId is null or empty, cannot setup stream');
        return;
      }

      // 🆕 Run cleanup when setting up stream
      await _cleanupExpiredSchedules();

      print('🔄 Setting up stream for connectionId: $_connectionId');

      // Cancel existing subscription if any
      _gamingSchedulesSubscription?.cancel();

      _gamingSchedulesSubscription = FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .snapshots()
          .listen(
            (DocumentSnapshot snapshot) {
          print('🔥 Firestore snapshot received');
          print('📄 Document exists: ${snapshot.exists}');

          if (!mounted) {
            print('⚠️ Widget not mounted, skipping update');
            return;
          }

          List<Map<String, dynamic>> newSchedules = [];

          if (snapshot.exists) {
            final data = snapshot.data() as Map<String, dynamic>?;
            print('📊 Raw document data: $data');

            if (data != null && data['schedules'] != null) {
              List<dynamic> schedules = data['schedules'];
              print('📋 Total schedules in document: ${schedules.length}');

              // <-- CHANGED: include paused schedules (status != completed && != cancelled)
              newSchedules = schedules
                  .where((schedule) {
                final status = (schedule['status'] ?? '').toString().toLowerCase();
                // Keep scheduled, active, paused, recurring entries — only hide completed/cancelled
                return status != 'completed' && status != 'cancelled';
              })
                  .map((schedule) => Map<String, dynamic>.from(schedule))
                  .toList();

              print('✅ Visible schedules filtered (includes paused): ${newSchedules.length}');
            }
          }

          setState(() {
            _gamingSchedules = newSchedules;
            print('🎯 UI updated with ${_gamingSchedules.length} schedules');
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              print('🔄 Post-frame callback: UI should now show ${_gamingSchedules.length} schedules');
            }
          });
        },
        onError: (error) {
          print('❌ Error in gaming schedules stream: $error');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error loading schedules: $error'),
                backgroundColor: Colors.red,
              ),
            );
          }
        },
      );

      print('✅ Stream setup completed for connectionId: $_connectionId');
    } catch (e) {
      print('❌ Error setting up gaming schedules stream: $e');
    }
  }

  Future<void> _loadGamingSchedules() async {
    try {
      print('📥 LOAD: Starting to load gaming schedules');

      if (_deviceId.isEmpty) {
        await _getDeviceId();
      }

      if (_connectionId == null || _connectionId!.isEmpty) {
        print('❌ LOAD: ConnectionId is null or empty, cannot load schedules');
        return;
      }

      print('📥 LOAD: Loading schedules for connectionId: $_connectionId');

      DocumentSnapshot snapshot = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .get();

      print('📥 LOAD: Document exists: ${snapshot.exists}');

      List<Map<String, dynamic>> loadedSchedules = [];

      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>?;
        print('📥 LOAD: Document data: $data');

        if (data != null && data['schedules'] != null) {
          List<dynamic> schedules = data['schedules'];
          print('📥 LOAD: Found ${schedules.length} total schedules');

          // <-- CHANGED: include paused schedules — keep non-completed/non-cancelled entries
          loadedSchedules = schedules
              .where((schedule) {
            final status = (schedule['status'] ?? '').toString().toLowerCase();
            return status != 'completed' && status != 'cancelled';
          })
              .map((schedule) => Map<String, dynamic>.from(schedule))
              .toList();

          print('📥 LOAD: Filtered to ${loadedSchedules.length} visible schedules (includes paused)');
        } else {
          print('📥 LOAD: No schedules field in document');
        }
      } else {
        print('📥 LOAD: Document does not exist');
      }

      if (mounted) {
        setState(() {
          _gamingSchedules = loadedSchedules;
          print('📥 LOAD: Updated _gamingSchedules to ${_gamingSchedules.length} items');
        });
      } else {
        print('❌ LOAD: Widget not mounted, skipping setState');
      }
    } catch (e) {
      print('❌ LOAD: Error loading gaming schedules: $e');
    }
  }

  Future<List<Map<String, dynamic>>?> loadGamingScheduleByConnectionId(String connectionId) async {
    try {
      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(connectionId)
          .get();

      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>?;
        if (data != null && data['schedules'] != null) {
          List<dynamic> schedules = data['schedules'];
          return schedules.map((schedule) => Map<String, dynamic>.from(schedule)).toList();
        }
      }
      return null;
    } catch (e) {
      print('Error loading gaming schedule by connectionId: $e');
      return null;
    }
  }

  Future<bool> updateScheduleStatus(String scheduleId, String newStatus) async {
    try {
      if (_connectionId == null || _connectionId!.isEmpty) return false;

      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .get();

      if (!doc.exists) return false;
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null || data['schedules'] == null) return false;

      List<dynamic> schedules = List.from(data['schedules']);

      bool updated = false;
      for (int i = 0; i < schedules.length; i++) {
        if (schedules[i]['id'] == scheduleId) {
          schedules[i]['status'] = newStatus;
          schedules[i]['updatedAt'] = Timestamp.fromDate(DateTime.now());
          // If marking as completed, also set isActive to false
          if (newStatus == 'completed') {
            schedules[i]['isActive'] = false;
          }
          updated = true;
          break;
        }
      }

      if (!updated) return false;

      await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .update({
        'schedules': schedules,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _updateAllowedGamesFromSchedules();
      return true;
    } catch (e) {
      print('Error updating schedule status: $e');
      return false;
    }
  }

  Future<bool> deleteGamingSchedule(String scheduleId) async {
    try {
      if (_connectionId == null || _connectionId!.isEmpty) {
        return false;
      }

      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .get();

      if (!doc.exists) return false;

      final data = doc.data() as Map<String, dynamic>?;
      if (data == null || data['schedules'] == null) return false;

      List<dynamic> schedules = List.from(data['schedules']);

      // Remove the schedule from array
      schedules.removeWhere((schedule) => schedule['id'] == scheduleId);

      // Update the document with modified schedules array
      await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .update({
        'schedules': schedules,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 🆕 UPDATE ALLOWED GAMES based on remaining schedules
      await _updateAllowedGamesFromSchedules();

      print('Gaming schedule deleted permanently: $scheduleId');
      print('Allowed games updated based on remaining schedules');

      return true;
    } catch (e) {
      print('Error deleting gaming schedule: $e');
      return false;
    }
  }

  Future<int> _getTodayPlayTimeSeconds() async {
    List<String> childDeviceIds = _pairedDevices.map((d) => d['childDeviceId'] as String).toList();
    DateTime now = DateTime.now();
    DateTime todayStart = DateTime(now.year, now.month, now.day); // midnight today
    DateTime todayEnd = todayStart.add(Duration(days: 1)); // midnight next day

    int totalSeconds = 0;

    for (final device in _pairedDevices) {
      final connectionId = device['id'];
      if (connectionId == null) continue;
      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('game_sessions')
          .doc(connectionId)
          .collection('sessions')
          .where('isActive', isEqualTo: false)
          .where('endedAt', isGreaterThan: Timestamp.fromDate(todayStart))
          .where('endedAt', isLessThan: Timestamp.fromDate(todayEnd))
          .get();

      for (var doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final playTime = data['totalPlayTimeSeconds'] ?? 0;
        totalSeconds += (playTime is int) ? playTime : int.tryParse(playTime.toString()) ?? 0;
      }

      // Optionally, add currently running sessions for today:
      QuerySnapshot liveSnap = await FirebaseFirestore.instance
          .collection('game_sessions')
          .doc(connectionId)
          .collection('sessions')
          .where('isActive', isEqualTo: true)
          .where('launchedAt', isGreaterThan: Timestamp.fromDate(todayStart))
          .get();

      for (var doc in liveSnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final playTime = data['totalPlayTimeSeconds'] ?? 0;
        totalSeconds += (playTime is int) ? playTime : int.tryParse(playTime.toString()) ?? 0;
      }
    }

    return totalSeconds;
  }

  Future<bool> _updateAllowedGamesFromSchedules({String? connectionId}) async {
    try {
      final targetConnectionId = (connectionId != null && connectionId.isNotEmpty) ? connectionId : _connectionId;
      if (targetConnectionId == null || targetConnectionId.isEmpty) {
        print('Error: connectionId is required for updating allowed games');
        return false;
      }

      // Read the gaming_scheduled doc for this connection
      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(targetConnectionId)
          .get();

      // We'll build two sets:
      // - allowSet: game names that should be allowed (active / scheduled)
      // - blockSet: game names that should be blocked because they are paused/pausing/pauseRequested
      final Set<String> allowSet = {};
      final Set<String> blockSet = {};

      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>?;
        if (data != null && data['schedules'] != null) {
          List<dynamic> schedules = data['schedules'];
          for (var schedule in schedules) {
            try {
              final String? gName = (schedule['gameName'] ?? schedule['packageName'])?.toString();
              if (gName == null) continue;
              final String status = (schedule['status'] ?? '').toString().toLowerCase();
              final bool isActive = schedule['isActive'] == true;
              final bool pauseRequested = schedule['pauseRequested'] == true;

              // Active / scheduled schedules should allow the game (subject to pause override below)
              if ((status == 'active' || status == 'scheduled') && isActive) {
                allowSet.add(gName);
              }

              // Any explicit pause or pending "pausing" should force-block the game
              if (status == 'paused' || status == 'pausing' || pauseRequested) {
                blockSet.add(gName);
              }
            } catch (e) {
              // ignore individual schedule parse errors
              print('[allowed] skip schedule due to error: $e');
            }
          }
        }
      }

      print('[allowed] allowSet=$allowSet blockSet=$blockSet for $targetConnectionId');

      // Fetch installed games for the targetConnectionId (PASS the id explicitly)
      List<Map<String, String>> installedGamesData = await _fetchInstalledGamesWithPackageNames(connectionId: targetConnectionId);

      Timestamp currentTimestamp = Timestamp.fromDate(DateTime.now());

      Map<String, dynamic> allowedGamesData = {
        'parentDeviceId': _deviceId,
        'connectionId': targetConnectionId,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Check if allowed_games document exists (so we can preserve unlockByKey/unlockExpiry)
      DocumentSnapshot allowedDoc = await FirebaseFirestore.instance
          .collection('allowed_games')
          .doc(targetConnectionId)
          .get();

      Map<String, dynamic> currentAllowedData = allowedDoc.exists ? (allowedDoc.data() as Map<String, dynamic>) : {};
      Map<String, dynamic> currentAllowedGamesMap = {};
      if (currentAllowedData['allowedGames'] != null) {
        for (var game in currentAllowedData['allowedGames']) {
          if (game != null && game['packageName'] != null) {
            currentAllowedGamesMap[game['packageName']] = game;
          }
        }
      }

      List<Map<String, dynamic>> allowedGames = [];
      for (Map<String, String> gameData in installedGamesData) {
        final String gameName = gameData['name']!;
        final String packageName = gameData['packageName']!;
        Map<String, dynamic>? previous = currentAllowedGamesMap[packageName];

        bool unlockByKey = previous?['unlockByKey'] == true;
        DateTime? unlockExpiry = previous?['unlockExpiry'] is Timestamp
            ? (previous!['unlockExpiry'] as Timestamp).toDate()
            : null;
        bool unlockedAndNotExpired = unlockByKey && unlockExpiry != null && unlockExpiry.isAfter(DateTime.now());

        // Decide final allowed flag:
        // - If unlockedByKey and not expired => allowed
        // - Else if gameName is in blockSet => NOT allowed
        // - Else if gameName is in allowSet => allowed
        // - Else NOT allowed
        bool isAllowed;
        if (unlockedAndNotExpired) {
          isAllowed = true;
        } else if (blockSet.contains(gameName)) {
          isAllowed = false;
        } else if (allowSet.contains(gameName)) {
          isAllowed = true;
        } else {
          isAllowed = false;
        }

        allowedGames.add({
          'gameName': gameName,
          'packageName': packageName,
          'isGameAllowed': isAllowed,
          'unlockByKey': unlockedAndNotExpired ? true : false,
          'unlockExpiry': unlockedAndNotExpired ? previous!['unlockExpiry'] : null,
          'updatedAt': currentTimestamp,
        });
      }

      allowedGamesData['allowedGames'] = allowedGames;

      // Save to Firestore in allowed_games doc for targetConnectionId
      await FirebaseFirestore.instance
          .collection('allowed_games')
          .doc(targetConnectionId)
          .set(allowedGamesData, SetOptions(merge: true));

      print('✅ Game permissions updated for connectionId: $targetConnectionId');
      print('   AllowedGames count: ${allowedGames.length}');

      return true;
    } catch (e, st) {
      print('❌ Error updating allowed games: $e\n$st');
      return false;
    }
  }

  Future<void> _notifyChildToEnforcePause(String connectionId, String? packageName) async {
    try {
      if (connectionId == null || connectionId.isEmpty) return;
      final docRef = FirebaseFirestore.instance.collection('paired_devices').doc(connectionId);

      // Write a small command object the child can listen for and act on.
      // Child should listen to paired_devices/<connectionId>.lastCommand snapshot and enforce immediately.
      await docRef.set({
        'lastCommand': {
          'action': 'applyPause',
          'packageName': packageName,
          'timestamp': FieldValue.serverTimestamp(),
        }
      }, SetOptions(merge: true));

      print('[notify] wrote applyPause command to paired_devices/$connectionId for $packageName');
    } catch (e, st) {
      print('[notify] error writing applyPause command: $e\n$st');
    }
  }

  Future<List<Map<String, dynamic>>> fetchRecentGameSessions() async {
    try {
      // If you want only for your paired children, filter by childDeviceId(s)
      List<String> childDeviceIds = _pairedDevices.map((d) => d['childDeviceId'] as String).toList();

      // Query for recent sessions (limit to, say, last 5 per device)
      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('game_sessions')
          .where('childDeviceId', whereIn: childDeviceIds)
          .orderBy('endedAt', descending: true)
          .limit(10) // adjust as needed
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return {
          'childDeviceId': data['childDeviceId'],
          'gameName': data['gameName'],
          'packageName': data['packageName'],
          'launchedAt': data['launchedAt'],
          'endedAt': data['endedAt'],
          'isActive': data['isActive'],
          'totalPlayTimeSeconds': data['totalPlayTimeSeconds'],
          // Add other fields as needed
        };
      }).toList();
    } catch (e) {
      print('Error fetching recent game sessions: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _fetchInstalledGamesWithPackageNames({String? connectionId}) async {
    try {
      final targetConnection = (connectionId != null && connectionId.isNotEmpty) ? connectionId : _connectionId;
      if (targetConnection == null || targetConnection.isEmpty) {
        print("Connection ID is empty, cannot fetch games with package names.");
        return [];
      }

      print("Fetching games with package names, connection ID: $targetConnection");

      DocumentSnapshot snapshot = await FirebaseFirestore.instance
          .collection('installed_games')
          .doc(targetConnection)
          .get();

      if (!snapshot.exists) {
        QuerySnapshot querySnapshot = await FirebaseFirestore.instance
            .collection('installed_games')
            .where('childDeviceId', isEqualTo: targetConnection)
            .limit(1)
            .get();
        if (querySnapshot.docs.isNotEmpty) snapshot = querySnapshot.docs.first;
      }

      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>?;
        if (data != null && data.containsKey('games') && data['games'] is List) {
          final List<Map<String, String>> gamesWithPackages = [];
          for (var gameEntry in (data['games'] as List)) {
            if (gameEntry is Map) {
              String? gameName;
              String? packageName;
              if (gameEntry.containsKey('name')) gameName = gameEntry['name'] as String?;
              else if (gameEntry.containsKey('appName')) gameName = gameEntry['appName'] as String?;
              if (gameEntry.containsKey('packageName')) packageName = gameEntry['packageName'] as String?;
              if (gameName != null && packageName != null) {
                gamesWithPackages.add({'name': gameName, 'packageName': packageName});
              }
            }
          }
          return gamesWithPackages;
        }
      }
      return [];
    } catch (e) {
      print('Error fetching installed games with package names: $e');
      return [];
    }
  }

  Future<bool> _updateScheduleInDatabase(Map<String, dynamic> originalSchedule, Map<String, dynamic> updatedSchedule) async {
    try {
      if (_connectionId == null || _connectionId!.isEmpty) return false;

      String scheduleId = originalSchedule['id'];

      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .get();

      if (!doc.exists) return false;

      final data = doc.data() as Map<String, dynamic>?;
      if (data == null || data['schedules'] == null) return false;

      List<dynamic> schedules = List.from(data['schedules']);

      bool updated = false;
      DateTime now = DateTime.now();
      Timestamp currentTimestamp = Timestamp.fromDate(now);

      for (int i = 0; i < schedules.length; i++) {
        if (schedules[i]['id'] == scheduleId) {
          schedules[i]['gameName'] = updatedSchedule['gameName'];
          schedules[i]['packageName'] = updatedSchedule['packageName']; // <-- FIX HERE!
          schedules[i]['scheduledDate'] = Timestamp.fromDate(updatedSchedule['scheduledDate']);
          schedules[i]['startTime'] = '${updatedSchedule['startTime'].hour.toString().padLeft(2, '0')}:${updatedSchedule['startTime'].minute.toString().padLeft(2, '0')}';
          schedules[i]['endTime'] = '${updatedSchedule['endTime'].hour.toString().padLeft(2, '0')}:${updatedSchedule['endTime'].minute.toString().padLeft(2, '0')}';
          schedules[i]['durationMinutes'] = updatedSchedule['durationMinutes'];
          schedules[i]['task'] = updatedSchedule['task'];
          schedules[i]['isRecurring'] = updatedSchedule['isRecurring'];
          schedules[i]['recurringDays'] = updatedSchedule['recurringDays'];
          schedules[i]['updatedAt'] = currentTimestamp;
          updated = true;
          break;
        }
      }

      if (!updated) return false;

      await FirebaseFirestore.instance
          .collection('gaming_scheduled')
          .doc(_connectionId!)
          .update({
        'schedules': schedules,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _updateAllowedGamesFromSchedules();

      print('Schedule updated and allowed games refreshed');

      return true;
    } catch (e) {
      print('Error updating schedule: $e');
      return false;
    }
  }

  Future<void> _saveSessionToLocalHistory(Map<String, dynamic> session) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = prefs.getStringList('weekly_game_sessions') ?? [];

    // Recursively convert all Timestamps and DateTime to ISO strings
    dynamic cleanseTimestamps(dynamic value) {
      if (value is Map) {
        return value.map((k, v) => MapEntry(k, cleanseTimestamps(v)));
      } else if (value is List) {
        return value.map((v) => cleanseTimestamps(v)).toList();
      } else if (value is Timestamp) {
        return value.toDate().toIso8601String();
      } else if (value is DateTime) {
        return value.toIso8601String();
      } else {
        return value;
      }
    }

    // Clone and cleanse
    Map<String, dynamic> fixedSession = Map<String, dynamic>.from(cleanseTimestamps(session));

    // Accept DateTime or Timestamp or String for endedAt (from the original session for keying/pruning)
    DateTime? endedAt;
    if (session['endedAt'] is Timestamp) {
      endedAt = (session['endedAt'] as Timestamp).toDate();
    } else if (session['endedAt'] is DateTime) {
      endedAt = session['endedAt'] as DateTime;
    } else if (session['endedAt'] is String) {
      endedAt = DateTime.tryParse(session['endedAt']);
    }
    if (endedAt == null) return;

    final now = DateTime.now();
    if (now.difference(endedAt).inDays > 7) return;

    final key = '${session['gameName']}_${endedAt.toIso8601String()}';
    fixedSession['key'] = key;
    if (history.any((entry) => (jsonDecode(entry)['key'] ?? '') == key)) return;

    history.add(jsonEncode(fixedSession));

    // Prune old entries (handle endedAt as String)
    final pruned = history.where((entry) {
      final data = jsonDecode(entry);
      DateTime? endedAt;
      if (data['endedAt'] is String) {
        endedAt = DateTime.tryParse(data['endedAt']);
      }
      return endedAt != null && now.difference(endedAt).inDays <= 7;
    }).toList();

    await prefs.setStringList('weekly_game_sessions', pruned);
  }

  Future<bool> _setAllowedGame(String connectionId, String packageName, bool isAllowed) async {
    try {
      if (connectionId == null || connectionId.isEmpty) return false;
      if (packageName == null || packageName.trim().isEmpty) return false;
      packageName = packageName.trim();

      // Try to fetch game name from installed games if missing
      String gameName = packageName;
      try {
        final installed = await _fetchInstalledGamesWithPackageNames(connectionId: connectionId);
        final match = installed.firstWhere((g) => g['packageName'] == packageName, orElse: () => {});
        if (match != null && match.isNotEmpty && match['name'] != null) {
          gameName = match['name']!;
        }
      } catch (e) { }

      final docRef = FirebaseFirestore.instance.collection('allowed_games').doc(connectionId);
      final docSnap = await docRef.get();

      List<dynamic> allowedGames = [];
      if (docSnap.exists && docSnap.data() != null) {
        final data = docSnap.data() as Map<String, dynamic>;
        allowedGames = List.from(data['allowedGames'] ?? []);
      }

      bool found = false;
      final nowTs = Timestamp.fromDate(DateTime.now());

      // Always find or create the entry
      for (int i = 0; i < allowedGames.length; i++) {
        final ag = Map<String, dynamic>.from(allowedGames[i]);
        if ((ag['packageName'] ?? '').toString().trim() == packageName) {
          ag['isGameAllowed'] = isAllowed;
          ag['unlockByKey'] = false;
          ag['unlockExpiry'] = null;
          ag['updatedAt'] = nowTs;
          allowedGames[i] = ag;
          found = true;
          break;
        }
      }

      if (!found) {
        allowedGames.add({
          'gameName': gameName,
          'packageName': packageName,
          'isGameAllowed': isAllowed,
          'unlockByKey': false,
          'unlockExpiry': null,
          'updatedAt': nowTs,
        });
      }

      await docRef.set({
        'parentDeviceId': _deviceId,
        'connectionId': connectionId,
        'allowedGames': allowedGames,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      print('[allowed] allowed_games updated for $connectionId: $packageName => $isAllowed');
      return true;
    } catch (e, st) {
      print('[allowed] error updating allowed_games: $e\n$st');
      return false;
    }
  }

  Future<bool> _setAllowedGameForSession(String connectionId, QueryDocumentSnapshot sessionDoc, bool isAllowed) async {
    try {
      final session = sessionDoc.data() as Map<String, dynamic>;
      String? packageName = (session['packageName'] as String?)?.trim();
      String? gameName = (session['gameName'] as String?)?.trim();

      if ((packageName == null || packageName.isEmpty) && (gameName == null || gameName.isEmpty)) {
        print('[allowed-session] session has no packageName or gameName, cannot update allowed_games');
        return false;
      }

      // Prefer packageName if available; otherwise try to map gameName -> package via installed_games
      if (packageName == null || packageName.isEmpty) {
        final installed = await _fetchInstalledGamesWithPackageNames(connectionId: connectionId);
        final match = installed.firstWhere((g) => g['name']?.toLowerCase() == gameName?.toLowerCase(), orElse: () => {});
        if (match != null && match.isNotEmpty) {
          packageName = match['packageName'];
        }
      }

      if (packageName == null || packageName.isEmpty) {
        print('[allowed-session] could not determine packageName for session; aborting');
        return false;
      }

      final ok = await _setAllowedGame(connectionId, packageName, isAllowed);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isAllowed ? 'Resumed — allowed_games updated' : 'Paused — allowed_games updated'),
            backgroundColor: isAllowed ? Colors.green : Colors.orange,
          ),
        );
      }
      return ok;
    } catch (e, st) {
      print('[allowed-session] error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update allowed game: $e'), backgroundColor: Colors.red),
        );
      }
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _getWeeklySessions() async {
    await _clearWeeklySessionsIfNeeded();
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = prefs.getStringList('weekly_game_sessions') ?? [];
    final now = DateTime.now();

    return history
        .map((entry) => jsonDecode(entry) as Map<String, dynamic>)
        .where((session) {
      DateTime? endedAt;
      final endedRaw = session['endedAt'];
      if (endedRaw is String) {
        endedAt = DateTime.tryParse(endedRaw);
      } else if (endedRaw is Map && endedRaw.containsKey('seconds')) {
        endedAt = DateTime.fromMillisecondsSinceEpoch(endedRaw['seconds'] * 1000);
      } else if (endedRaw is Timestamp) {
        endedAt = endedRaw.toDate();
      } else if (endedRaw is DateTime) {
        endedAt = endedRaw;
      }
      return endedAt != null && now.difference(endedAt).inDays <= 7;
    })
        .toList();
  }

  Future<Map<String, int>> getWeeklyGamePlayTotals() async {
    // Map<gameName, totalPlayTimeSeconds>
    Map<String, int> gameTotals = {};
    final now = DateTime.now();
    final startOfWeek = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1)); // Monday at midnight

    print('===== Weekly GamePlay Totals DEBUG =====');
    print('Current time: $now');
    print('Start of week: $startOfWeek');
    print('Paired Devices:');
    for (final device in _pairedDevices) {
      print('  - ${device['id']} (childDeviceId: ${device['childDeviceId']})');
    }

    for (final device in _pairedDevices) {
      final connectionId = device['id'];
      if (connectionId == null) {
        print('[WARN] Skipping device with null connectionId');
        continue;
      }

      print('Querying sessions for connectionId: $connectionId');

      QuerySnapshot sessionsSnap;
      try {
        sessionsSnap = await FirebaseFirestore.instance
            .collection('game_sessions')
            .doc(connectionId)
            .collection('sessions')
            .where('isActive', isEqualTo: false)
            .where('endedAt', isGreaterThan: Timestamp.fromDate(startOfWeek))
            .get();
      } catch (e) {
        print('[ERROR] Firestore query failed for $connectionId: $e');
        continue;
      }
      print('  Found ${sessionsSnap.docs.length} ended sessions for this week.');

      for (final doc in sessionsSnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        print('  SessionId: ${doc.id} data: $data');

        final gameName = data['gameName'] ?? 'Unknown Game';
        final playTime = data['totalPlayTimeSeconds'] ?? 0;
        final endedAtRaw = data['endedAt'];
        DateTime? endedAt;
        if (endedAtRaw is Timestamp) endedAt = endedAtRaw.toDate();
        else if (endedAtRaw is DateTime) endedAt = endedAtRaw;
        else if (endedAtRaw is String) endedAt = DateTime.tryParse(endedAtRaw);

        final isActive = data['isActive'] ?? false;
        print('    - gameName: $gameName');
        print('    - playTime: $playTime');
        print('    - endedAt: $endedAtRaw (parsed: $endedAt)');
        print('    - isActive: $isActive');
        print('    - week filter pass: ${endedAt != null && endedAt.isAfter(startOfWeek)}');

        final playTimeInt = (playTime is int) ? playTime : (playTime is num) ? playTime.toInt() : int.tryParse(playTime.toString()) ?? 0;
        gameTotals[gameName] = (gameTotals[gameName] ?? 0) + playTimeInt;
        print('    -> Aggregated: $gameName = ${gameTotals[gameName]}s');
      }
    }
    print('Final gameTotals: $gameTotals');
    print('===== END Weekly GamePlay Totals DEBUG =====');
    return gameTotals;
  }

  Future<int> _getWeeklyPlayTimeSeconds() async {
    List<String> childDeviceIds = _pairedDevices.map((d) => d['childDeviceId'] as String).toList();
    DateTime now = DateTime.now();
    DateTime startWk = _startOfWeek(now);
    DateTime endWk = _endOfWeek(now);

    QuerySnapshot snapshot = await FirebaseFirestore.instance
        .collection('game_sessions')
        .where('childDeviceId', whereIn: childDeviceIds)
        .get();

    int totalSeconds = 0;
    for (var doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;
      DateTime? endedAt;
      DateTime? launchedAt;

      if (data['endedAt'] is Timestamp) endedAt = (data['endedAt'] as Timestamp).toDate();
      else if (data['endedAt'] is DateTime) endedAt = data['endedAt'];
      else if (data['endedAt'] is String) endedAt = DateTime.tryParse(data['endedAt']);

      if (data['launchedAt'] is Timestamp) launchedAt = (data['launchedAt'] as Timestamp).toDate();
      else if (data['launchedAt'] is DateTime) launchedAt = data['launchedAt'];
      else if (data['launchedAt'] is String) launchedAt = DateTime.tryParse(data['launchedAt']);

      bool isInWeek(DateTime? dt) =>
          dt != null && !dt.isBefore(startWk) && !dt.isAfter(endWk);

      if (isInWeek(endedAt) || (data['isActive'] == true && isInWeek(launchedAt))) {
        totalSeconds += (data['totalPlayTimeSeconds'] ?? 0) as int;
      }
    }
    return totalSeconds;
  }

  DateTime getStartOfWeek(DateTime now) {
    // Monday = 1, Sunday = 7
    int daysToSubtract = now.weekday - DateTime.monday;
    return DateTime(now.year, now.month, now.day).subtract(Duration(days: daysToSubtract));
  }

  Future<void> _clearWeeklySessionsIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final lastResetIso = prefs.getString('last_weekly_reset');
    DateTime? lastReset = lastResetIso != null ? DateTime.tryParse(lastResetIso) : null;

    // If today is Monday and either never reset or last reset was before this Monday
    if (now.weekday == DateTime.monday &&
        (lastReset == null || lastReset.isBefore(getStartOfWeek(now)))) {
      await prefs.setStringList('weekly_game_sessions', []);
      await prefs.setString('last_weekly_reset', now.toIso8601String());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2D3748),
      appBar: _buildAppBar(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFE07A39)))
          : _buildCurrentTab(),
      bottomNavigationBar: _buildBottomNavBar(),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: Row(
        children: [
          CircleAvatar(
            backgroundColor: const Color(0xFFE07A39),
            child: const Icon(Icons.person, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          const Text(
            'Welcome, Parent!',
            style: TextStyle(fontWeight: FontWeight.w500, color: Colors.white, fontSize: 18),
          ),
        ],
      ),
      backgroundColor: const Color(0xFF2D3748),
      elevation: 0,
    );
  }

  Widget _buildBottomNavBar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2D3748),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFF2D3748),
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        selectedItemColor: const Color(0xFFE07A39),
        unselectedItemColor: const Color(0xFF718096),
        selectedLabelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.schedule), label: 'Schedule'),
          BottomNavigationBarItem(icon: Icon(Icons.task), label: 'Tasks'),
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.sports_esports), label: 'Gaming'),
          BottomNavigationBarItem(icon: Icon(Icons.tune), label: 'Manage'),
        ],
      ),
    );
  }

  Widget _buildCurrentTab() {
    switch (_selectedIndex) {
      case 0:
        return _buildScheduleTab();
      case 1:
        return _buildTasksTab();
      case 2:
        return _buildDashboardTab();
      case 3:
        return _buildGamesTab();
      case 4:
        return _buildSettingsTab();
      default:
        return _buildDashboardTab();
    }
  }

  Widget _buildDashboardTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildCard(
            'Paired Devices',
            Icons.devices,
            _pairedDevices.isEmpty ? _buildEmptyDevices() : _buildDevicesList(),
          ),
          const SizedBox(height: 20),
          _buildCard(
            'Today\'s Overview',
            Icons.dashboard,
            _buildQuickStats(),
          ),
          const SizedBox(height: 20),
          _buildCard(
            'Recent Activity',
            Icons.history,
            _buildActivityList('today'),
          ),
          const SizedBox(height: 20),
          _buildWeeklyReportCard(),
        ],
      ),
    );
  }

  Widget _buildScheduleTab() {
    // Filter schedules
    final archivedSchedules = _gamingSchedules.where((s) {
      final status = (s['status'] ?? '').toLowerCase();
      return status == 'completed' || status == 'cancelled';
    }).toList();

    final activeSchedules = _gamingSchedules.where((s) {
      final status = (s['status'] ?? '').toLowerCase();
      return status != 'completed' && status != 'cancelled';
    }).toList();

    bool showArchived = archivedSchedules.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          const Text(
            'Gaming Schedules',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            '${activeSchedules.length}/$MAX_SCHEDULES_PER_CONNECTION schedules created',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
          const SizedBox(height: 12),
          // Show Add button if the limit is not reached
          if (activeSchedules.length < MAX_SCHEDULES_PER_CONNECTION)
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: _addNewSchedule,
                icon: const Icon(Icons.add, color: Colors.white),
                label: const Text('Add Gaming Schedule', style: TextStyle(color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE07A39),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
          const SizedBox(height: 12),

          // Active Schedules List
          Expanded(
            child: activeSchedules.isEmpty
                ? _buildEmptySchedules()
                : _buildSchedulesList(activeSchedules),
          ),

          // Archived Section (with toggle)
          if (showArchived)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 24),
                Row(
                  children: [
                    Icon(Icons.archive, color: Colors.orange),
                    const SizedBox(width: 8),
                    Text(
                      'Archived Schedules',
                      style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...archivedSchedules.map((schedule) => _buildArchivedScheduleCard(schedule)).toList(),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildArchivedScheduleCard(Map<String, dynamic> schedule) {
    String formattedDate = 'N/A';
    if (schedule['scheduledDate'] is Timestamp) {
      final date = (schedule['scheduledDate'] as Timestamp).toDate();
      formattedDate = '${date.day}/${date.month}/${date.year}';
    }
    return Card(
      color: Colors.grey[850],
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(Icons.archive, color: Colors.orange),
        title: Text(
          schedule['gameName'] ?? 'Unknown Game',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          'Device: ${_getChildDeviceNameFromSchedule(schedule['childDeviceId'])}\n'
              'Date: $formattedDate\n'
              'Time: ${schedule['startTime']} - ${schedule['endTime']}\n'
              'Duration: ${schedule['durationMinutes'] ?? 0} minutes',
          style: TextStyle(color: Colors.grey[300], fontSize: 13),
        ),
        trailing: Text(
          (schedule['status'] ?? '').toString().toUpperCase(),
          style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildEmptySchedules() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.schedule, size: 80, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text('No gaming schedules created yet', style: TextStyle(fontSize: 18, color: Colors.grey[400])),
          const SizedBox(height: 8),
          Text('Create your first gaming schedule to manage screen time', style: TextStyle(color: Colors.grey[500])),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _addNewSchedule,
            icon: const Icon(Icons.schedule),
            label: const Text('Add Gaming Schedule'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE07A39),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSchedulesList(List<Map<String, dynamic>> schedules) {
    if (schedules.isEmpty) {
      return _buildEmptySchedules(); // fallback, just in case
    }
    return ListView.builder(
      itemCount: schedules.length,
      itemBuilder: (context, index) {
        final schedule = schedules[index];

        // Parse and format times
        TimeOfDay? startTime;
        TimeOfDay? endTime;
        try {
          if (schedule['startTime'] is String) {
            final startParts = schedule['startTime'].split(':');
            startTime = TimeOfDay(
                hour: int.parse(startParts[0]), minute: int.parse(startParts[1]));
          }
          if (schedule['endTime'] is String) {
            final endParts = schedule['endTime'].split(':');
            endTime = TimeOfDay(
                hour: int.parse(endParts[0]), minute: int.parse(endParts[1]));
          }
        } catch (e) {
          print('Error parsing time: $e');
        }

        // Format date
        String formattedDate = 'N/A';
        if (schedule['scheduledDate'] is Timestamp) {
          final date = (schedule['scheduledDate'] as Timestamp).toDate();
          formattedDate = '${date.day}/${date.month}/${date.year}';
        }

        // Status and color
        final status = (schedule['status'] ?? 'scheduled').toString().toLowerCase();
        Color statusColor;
        switch (status) {
          case 'active':
            statusColor = Colors.green;
            break;
          case 'completed':
            statusColor = Colors.blue;
            break;
          case 'cancelled':
            statusColor = Colors.red;
            break;
          default:
            statusColor = const Color(0xFFE07A39);
        }

        // Is archived?
        final isArchived = status == 'completed' || status == 'cancelled';

        return Card(
          color: isArchived ? Colors.grey[850] : const Color(0xFF4A5568),
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: isArchived
                  ? Border.all(color: Colors.orange, width: 2)
                  : status == 'active'
                  ? Border.all(color: Colors.green, width: 2)
                  : null,
            ),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: isArchived
                    ? Colors.orange
                    : status == 'active'
                    ? Colors.green
                    : const Color(0xFFE07A39),
                child: Icon(
                  isArchived
                      ? Icons.archive
                      : status == 'active'
                      ? Icons.play_arrow
                      : Icons.videogame_asset,
                  color: Colors.white,
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      schedule['gameName']?.toString() ?? 'Unknown Game',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    'Device: ${_getChildDeviceNameFromSchedule(schedule['childDeviceId'])}',
                    style: TextStyle(color: Colors.grey[300]),
                  ),
                  Text(
                    'Date: $formattedDate',
                    style: TextStyle(color: Colors.grey[300]),
                  ),
                  Text(
                    'Time: ${startTime?.format(context) ?? 'N/A'} - ${endTime?.format(context) ?? 'N/A'}',
                    style: TextStyle(color: Colors.grey[300]),
                  ),
                  Text(
                    'Duration: ${schedule['durationMinutes'] ?? 0} minutes',
                    style: TextStyle(color: Colors.grey[300]),
                  ),
                  if (schedule['task'] != null && schedule['task'].toString().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Task: ${schedule['task']}',
                        style: TextStyle(color: Colors.orange, fontStyle: FontStyle.italic),
                      ),
                    ),
                  if ((schedule['status'] ?? '').toString().toLowerCase() == 'paused' || schedule['pauseRequested'] == true)
                    FutureBuilder<bool>(
                      future: isSessionActive(schedule['childDeviceId'], schedule['packageName']),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return Row(
                            children: [
                              CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Pausing the game, please wait. This might take a minute...',
                                  style: TextStyle(color: Colors.orange, fontSize: 13),
                                ),
                              ),
                            ],
                          );
                        }
                        if (snapshot.data == true) {
                          return Row(
                            children: [
                              CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Pausing the game, please wait. This might take a minute...',
                                  style: TextStyle(color: Colors.orange, fontSize: 13),
                                ),
                              ),
                            ],
                          );
                        } else {
                          // Session has finished: show nothing extra (or show "Paused")
                          return SizedBox.shrink();
                        }
                      },
                    ),
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      // show PAUSING when status == 'pausing'
                      (status == 'pausing' ? 'PAUSING' : (schedule['status']?.toString().toUpperCase() ?? 'SCHEDULED')),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              trailing: isArchived
                  ? null
                  : PopupMenuButton(
                color: const Color(0xFF2D3748),
                itemBuilder: (context) {
                  final status = (schedule['status'] ?? 'scheduled').toString().toLowerCase();
                  final isPausing = status == 'pausing' || schedule['pauseRequested'] == true;
                  final isPaused = (schedule['status'] ?? '').toString().toLowerCase() == 'paused';
                  return [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit, color: Colors.white, size: 18),
                          SizedBox(width: 8),
                          Text('Edit', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: isPaused ? 'resume' : 'pause',
                      child: Row(
                        children: [
                          Icon(isPaused ? Icons.play_arrow : Icons.pause, color: Colors.white, size: 18),
                          SizedBox(width: 8),
                          Text(isPaused ? 'Resume' : 'Pause', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: const Row(
                        children: [
                          Icon(Icons.delete, color: Colors.red, size: 18),
                          SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ];
                },
                onSelected: (value) {
                  if (value == 'edit') {
                    _editSchedule(schedule);
                  } else if (value == 'delete') {
                    _deleteScheduleFromList(schedule);
                  } else if (value == 'pause') {
                    _pauseSchedule(schedule['id']);
                  } else if (value == 'resume') {
                    _resumeSchedule(schedule['id']);
                  }
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> isSessionActive(String childDeviceId, String packageName) async {
    final query = await FirebaseFirestore.instance
        .collection('game_sessions')
        .where('childDeviceId', isEqualTo: childDeviceId)
        .where('packageName', isEqualTo: packageName)
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    return query.docs.isNotEmpty;
  }

  Future<bool> _pauseSchedule(String scheduleId, {String? connectionId}) async {
    final targetConnectionId = (connectionId != null && connectionId.isNotEmpty) ? connectionId : _connectionId;
    if (targetConnectionId == null || targetConnectionId.isEmpty) {
      print('[pause] no connectionId available');
      return false;
    }

    try {
      final docRef = FirebaseFirestore.instance.collection('gaming_scheduled').doc(targetConnectionId);
      final snap = await docRef.get();
      if (!snap.exists || snap.data() == null) {
        print('[pause] gaming_scheduled doc not found for $targetConnectionId');
        return false;
      }

      Map<String, dynamic> data = Map<String, dynamic>.from(snap.data() as Map<String, dynamic>);
      bool didChange = false;

      // 1) If there is a 'schedules' List, handle the normal case
      if (data.containsKey('schedules') && data['schedules'] is List) {
        List<dynamic> schedules = List<dynamic>.from(data['schedules']);
        for (int i = 0; i < schedules.length; i++) {
          final s = schedules[i] as Map<String, dynamic>;
          final sId = s['id']?.toString() ?? '';
          if (sId == scheduleId.toString()) {
            print('[pause] matched schedule in schedules list (index $i) id=$sId');
            schedules[i]['status'] = 'paused';
            schedules[i]['isActive'] = false;
            schedules[i]['pauseRequested'] = true; // keep for child enforcement if needed
            schedules[i]['pauseRequestedAt'] = Timestamp.fromDate(DateTime.now());
            schedules[i]['updatedAt'] = Timestamp.fromDate(DateTime.now());
            didChange = true;
            break;
          }
        }
        if (didChange) {
          await docRef.update({'schedules': schedules, 'updatedAt': FieldValue.serverTimestamp()});
          print('[pause] updated schedules list for $targetConnectionId');
        }
      } else {
        // 2) No 'schedules' list — doc may be a single schedule or numeric-keyed schedule map (like your screenshot)
        // Check if root looks like a schedule object (has gameName/childDeviceId/id)
        bool rootLooksLikeSchedule = data.containsKey('gameName') && data.containsKey('id');
        if (rootLooksLikeSchedule) {
          final rootId = (data['id'] ?? '').toString();
          print('[pause] doc root looks like single schedule, rootId=$rootId');
          if (rootId == scheduleId.toString()) {
            // update root fields directly
            data['status'] = 'paused';
            data['isActive'] = false;
            data['updatedAt'] = Timestamp.fromDate(DateTime.now());
            await docRef.set(data, SetOptions(merge: true));
            didChange = true;
            print('[pause] updated root schedule fields for $targetConnectionId');
          }
        } else {
          // 3) Possibly numeric keys mapping to schedule objects (e.g., "0": {...}, "7": {...})
          // Iterate keys and look for nested maps that contain 'id'.
          final updatedData = Map<String, dynamic>.from(data);
          for (final key in data.keys) {
            final val = data[key];
            if (val is Map) {
              final nested = Map<String, dynamic>.from(val);
              final nestedId = (nested['id'] ?? '').toString();
              if (nestedId == scheduleId.toString()) {
                print('[pause] matched schedule in numeric-key map key=$key id=$nestedId');
                nested['status'] = 'paused';
                nested['isActive'] = false;
                nested['updatedAt'] = Timestamp.fromDate(DateTime.now());
                updatedData[key] = nested;
                didChange = true;
                break;
              }
            }
          }
          if (didChange) {
            await docRef.set(updatedData, SetOptions(merge: true));
            print('[pause] updated numeric-key schedule in doc $targetConnectionId');
          }
        }
      }

      if (didChange) {
        // Update allowed_games for that connection (pass connectionId explicitly)
        await _updateAllowedGamesFromSchedules(connectionId: targetConnectionId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The game will be block'), backgroundColor: Colors.orange));
        }
        return true;
      } else {
        print('[pause] no matching schedule id=$scheduleId found in doc $targetConnectionId');
        return false;
      }
    } catch (e, st) {
      print('[pause] Error pausing schedule id=$scheduleId on connection=${connectionId ?? _connectionId}: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to pause schedule: $e'), backgroundColor: Colors.red));
      }
      return false;
    }
  }

  Future<bool> _resumeSchedule(String scheduleId, {String? connectionId}) async {
    final targetConnectionId = (connectionId != null && connectionId.isNotEmpty) ? connectionId : _connectionId;
    if (targetConnectionId == null || targetConnectionId.isEmpty) return false;

    try {
      final docRef = FirebaseFirestore.instance.collection('gaming_scheduled').doc(targetConnectionId);
      final doc = await docRef.get();
      if (!doc.exists) return false;
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null || data['schedules'] == null) return false;

      List<dynamic> schedules = List.from(data['schedules']);
      bool changed = false;
      for (var s in schedules) {
        if (s['id'] == scheduleId) {
          s['status'] = 'scheduled';
          s['isActive'] = true; // resume making it active again
          s['updatedAt'] = Timestamp.fromDate(DateTime.now());
          // REMOVE ALL pause-related flags that block games
          s.remove('pauseRequested');
          s.remove('pauseRequestedAt');
          s.remove('pauseEtaSeconds');
          s.remove('pauseRequestedBy');
          changed = true;
          break;
        }
      }

      if (changed) {
        await docRef.update({
          'schedules': schedules,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        // Ensure allowed_games is updated for the same connectionId
        await _updateAllowedGamesFromSchedules(connectionId: targetConnectionId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Schedule resumed'), backgroundColor: Colors.green),
          );
        }
        return true;
      }
      return false;
    } catch (e) {
      print('Error resuming schedule: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resume schedule: $e'), backgroundColor: Colors.red),
        );
      }
      return false;
    }
  }

  Color _getStatusColor(String? status) {
    switch (status?.toLowerCase()) {
      case 'active':
        return Colors.green;
      case 'completed':
        return Colors.blue;
      case 'cancelled':
        return Colors.red;
      default:
        return const Color(0xFFE07A39);
    }
  }

  String _getChildDeviceNameFromSchedule(String? childDeviceId) {
    if (childDeviceId == null) return 'Unknown Device';

    try {
      final pairedDevice = _pairedDevices.firstWhere(
            (device) => device['childDeviceId'] == childDeviceId,
        orElse: () => <String, dynamic>{},
      );

      if (pairedDevice.isEmpty) return 'Unknown Device';

      final childDeviceInfo = pairedDevice['childDeviceInfo'] as Map<String, dynamic>? ?? {};
      final deviceBrand = childDeviceInfo['brand']?.toString() ?? 'Unknown';
      final deviceModel = childDeviceInfo['device']?.toString() ?? 'Device';
      return '$deviceBrand $deviceModel';
    } catch (e) {
      print('Error getting device name: $e');
      return 'Unknown Device';
    }
  }

  Widget _buildGamesTab() {
    // Group activities by device, styled similar to "Tasks & Rewards" tab UI
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Gaming Activity', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              DropdownButton<String>(
                value: _selectedActivityFilter,
                dropdownColor: const Color(0xFF4A5568),
                style: const TextStyle(color: Colors.white),
                items: const [
                  DropdownMenuItem(value: 'today', child: Text('Today')),
                  DropdownMenuItem(value: 'lastweek', child: Text('Last Week')),
                  DropdownMenuItem(value: 'lastmonth', child: Text('Last Month')),
                ],
                onChanged: (value) { setState(() { _selectedActivityFilter = value ?? 'today'; }); },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: _buildGroupedGameSessions()), // <-- new method
        ],
      ),
    );
  }

  DateTimeRange _getDateRangeForFilter(String filter) {
    final now = DateTime.now();
    if (filter == 'today') {
      final start = DateTime(now.year, now.month, now.day, 0, 0, 0);
      final end = start.add(Duration(days: 1));
      return DateTimeRange(start: start, end: end);
    } else if (filter == 'lastweek') {
      final currentWeekDay = now.weekday;
      final startOfWeek = now.subtract(Duration(days: currentWeekDay - 1));
      final lastWeekEnd = startOfWeek;
      final lastWeekStart = lastWeekEnd.subtract(Duration(days: 7));
      return DateTimeRange(start: lastWeekStart, end: lastWeekEnd);
    } else if (filter == 'lastmonth') {
      final startOfThisMonth = DateTime(now.year, now.month, 1);
      final lastMonthEnd = startOfThisMonth;
      final lastMonthStart = lastMonthEnd.month == 1
          ? DateTime(lastMonthEnd.year - 1, 12, 1)
          : DateTime(lastMonthEnd.year, lastMonthEnd.month - 1, 1);
      return DateTimeRange(start: lastMonthStart, end: lastMonthEnd);
    }
    // fallback to today
    final start = DateTime(now.year, now.month, now.day, 0, 0, 0);
    final end = start.add(Duration(days: 1));
    return DateTimeRange(start: start, end: end);
  }

  Widget _buildGroupedGameSessions() {
    if (_pairedDevices.isEmpty) return _buildEmptyActivity();

    return ListView(
      children: _pairedDevices.map((device) {
        final childDeviceId = device['childDeviceId'];
        final connectionId = device['id'];
        final childName = _getChildDeviceNameFromSchedule(childDeviceId);
        final dateRange = _getDateRangeForFilter(_selectedActivityFilter);

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('game_sessions')
              .doc(connectionId)
              .collection('sessions')
              .where('launchedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(dateRange.start))
              .where('launchedAt', isLessThan: Timestamp.fromDate(dateRange.end))
              .orderBy('launchedAt', descending: true)
              .limit(20)
              .snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
              return ListTile(
                leading: Icon(Icons.sports_esports_outlined, color: Colors.grey),
                title: Text(childName, style: TextStyle(color: Colors.white)),
                subtitle: Text('No recent gaming activity', style: TextStyle(color: Colors.grey[400])),
              );
            }

            final sessions = snapshot.data!.docs.map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final gameName = data['gameName'] ?? data['packageName'] ?? 'Unknown Game';
              final isActive = data['isActive'] == true;
              final playTime = Duration(seconds: data['totalPlayTimeSeconds'] ?? 0);

              DateTime? launchedAt;
              if (data['launchedAt'] is Timestamp) {
                launchedAt = (data['launchedAt'] as Timestamp).toDate();
              }

              DateTime? endedAt;
              if (data['endedAt'] is Timestamp) {
                endedAt = (data['endedAt'] as Timestamp).toDate();
              }

              return {
                'gameName': gameName,
                'isActive': isActive,
                'playTime': playTime,
                'launchedAt': launchedAt,
                'endedAt': endedAt,
              };
            }).toList();

            return ExpansionTile(
              title: Text(childName, style: TextStyle(color: Colors.white)),
              children: sessions.map((session) =>
                  ListTile(
                    leading: Icon(
                      session['isActive'] ? Icons.play_circle : Icons.history,
                      color: session['isActive'] ? Colors.green : Colors.grey,
                    ),
                    title: Text(session['gameName'], style: TextStyle(color: Colors.white)),
                    subtitle: Text(
                      session['isActive'] ?
                      'LIVE • Playing for ${_formatDuration(session['playTime'])}' :
                      'Ended • Played for ${_formatDuration(session['playTime'])}',
                      style: TextStyle(color: session['isActive'] ? Colors.green : Colors.grey[400]),
                    ),
                    trailing: session['isActive']
                        ? Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(12)),
                      child: Text('LIVE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    )
                        : null,
                  )
              ).toList(),
            );
          },
        );
      }).toList(),
    );
  }

  Widget _buildTasksTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Tasks & Rewards', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              ElevatedButton.icon(
                icon: Icon(Icons.add, color: Colors.white),
                label: Text('Add Task', style: TextStyle(color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE07A39),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onPressed: _showAddTaskDialog,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: _buildTasksList()),
        ],
      ),
    );
  }

  void _showAddTaskDialog() {
    showDialog(
      context: context,
      builder: (context) => _AddTaskDialog(
          pairedDevices: _pairedDevices,
          onTaskAdded: (selectedConnectionId, selectedChildDeviceId, tasks) async {
            DateTime now = DateTime.now();
            Timestamp currentTimestamp = Timestamp.fromDate(now);

            DocumentReference docRef = FirebaseFirestore.instance
                .collection('task_and_rewards')
                .doc(selectedConnectionId);

            DocumentSnapshot docSnap = await docRef.get();
            List<dynamic> tasksArray = [];
            if (docSnap.exists && docSnap.data() != null && (docSnap.data() as Map<String, dynamic>)['tasks'] != null) {
              tasksArray = List.from((docSnap.data() as Map<String, dynamic>)['tasks']);
            }

            // Add each task from dialog
            for (var t in tasks) {
              var newTask = {
                'task': t['name'],
                'reward': {
                  'points': t['points'],
                  'status': 'pending',
                },
                'childDeviceId': selectedChildDeviceId,
                'parentDeviceId': _deviceId,
                'createdAt': currentTimestamp,
                'updatedAt': currentTimestamp,
              };

              // Only add scheduleId/scheduledDate if NOT null
              if (t['scheduleId'] != null) newTask['scheduleId'] = t['scheduleId'];
              if (t['scheduledDate'] != null) newTask['scheduledDate'] = t['scheduledDate'];

              tasksArray.add(newTask);
            }

            await docRef.set({
              'tasks': tasksArray,
              'parentDeviceId': _deviceId,
              'connectionId': selectedConnectionId,
              'updatedAt': currentTimestamp,
            }, SetOptions(merge: true));

            // Refresh UI
            setState(() {});
            Navigator.pop(context);
          }
      ),
    );
  }

  Widget _buildSettingsTab() {
    // Show installed games for the currently selected child device(s)
    // For simplicity, only show for the first paired device
    if (_pairedDevices.isEmpty) {
      return Center(
        child: Text(
          'No paired devices found',
          style: TextStyle(color: Colors.grey[400], fontSize: 16),
        ),
      );
    }

    final device = _pairedDevices.first;
    final connectionId = device['id'];

    // Use FutureBuilder to load games from Firestore
    return Padding(
      padding: const EdgeInsets.all(16),
      child: FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance.collection('installed_games').doc(connectionId).get(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return Center(
              child: CircularProgressIndicator(color: Color(0xFFE07A39)),
            );
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          final games = List<Map<String, dynamic>>.from(data['games'] ?? []);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Installed Games', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              SizedBox(height: 12),

              FutureBuilder<DocumentSnapshot>(
                future: FirebaseFirestore.instance.collection('allowed_games').doc(connectionId).get(),
                builder: (context, allowedSnap) {
                  Map<String, dynamic> allowedData = allowedSnap.hasData && allowedSnap.data!.exists
                      ? allowedSnap.data!.data() as Map<String, dynamic>
                      : {};
                  List<dynamic> allowedGames = allowedData['allowedGames'] ?? [];

                  return Expanded(
                    child: ListView(
                      children: games.map((game) {
                        // Find status info from allowed_games
                        final packageName = game['packageName'];
                        final gameName = game['name'];
                        final statusObj = allowedGames.firstWhere(
                              (ag) => ag['packageName'] == packageName,
                          orElse: () => null,
                        );
                        final isAllowed = statusObj != null ? (statusObj['isGameAllowed'] ?? false) : false;

                        // Grab icon if available, else fallback
                        Widget gameIcon;
                        if (game.containsKey('iconStorageUrl') && game['iconStorageUrl'] != null) {
                          gameIcon = ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              game['iconStorageUrl'],
                              width: 40, height: 40, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Icon(Icons.games, color: Colors.white),
                            ),
                          );
                        } else if (game.containsKey('iconBase64') && game['iconBase64'] != null && game['iconBase64'].length > 100) {
                          gameIcon = ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              base64Decode(game['iconBase64']),
                              width: 40, height: 40, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Icon(Icons.games, color: Colors.white),
                            ),
                          );
                        } else {
                          gameIcon = Icon(Icons.games, color: isAllowed ? Colors.green : Colors.red, size: 36);
                        }

                        return Card(
                          color: Color(0xFF30343F), // Style like your screenshot
                          margin: EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          child: ListTile(
                            leading: gameIcon, // see the fixed code above
                            title: Text(gameName ?? '', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                            subtitle: Text(
                              '${game['category'] ?? 'Game'}',
                              style: TextStyle(color: Colors.grey[400], fontSize: 13),
                            ),
                            trailing: Switch(
                              value: isAllowed,
                              activeColor: Colors.green,
                              inactiveThumbColor: Colors.red,
                              onChanged: (val) async {
                                setState(() {});
                                await _setIsGameAllowed(connectionId, packageName, val);
                              },
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCard(String title, IconData icon, Widget content) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF4A5568),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFFE07A39), size: 24),
              const SizedBox(width: 12),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 20),
          content,
        ],
      ),
    );
  }

  Widget _buildEmptyDevices() {
    return Column(
      children: [
        Icon(Icons.devices_outlined, size: 64, color: Colors.grey[600]),
        const SizedBox(height: 16),
        Text('No paired devices found', style: TextStyle(color: Colors.grey[400], fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Text('Pair a player device to get started', style: TextStyle(color: Colors.grey[500], fontSize: 14)),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _addNewChild,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE07A39),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_link, size: 20),
                SizedBox(width: 8),
                Text('Pair Device', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDevicesList() {
    return Column(
      children: _pairedDevices.map((device) => _buildDeviceItem(device)).toList(),
    );
  }

  Widget _buildDeviceItem(Map<String, dynamic> device) {
    final childDeviceInfo = device['childDeviceInfo'] as Map<String, dynamic>? ?? {};
    final deviceBrand = childDeviceInfo['brand'] ?? 'Unknown';
    final deviceModel = childDeviceInfo['device'] ?? 'Unknown Device';
    final deviceName = '$deviceBrand $deviceModel';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF2D3748), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFE07A39).withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.phone_android, color: const Color(0xFFE07A39), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(deviceName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
          ),

        ],
      ),
    );
  }

  Widget _buildQuickStats() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildStatItem('Scheduled Games', '${_getScheduledGamesCount()}')),
            Expanded(
              child: FutureBuilder<int>(
                future: _getPendingRewardsCount(),
                builder: (context, snapshot) {
                  final value = snapshot.data ?? 0;
                  return _buildStatItem('Pending Rewards', '$value');
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FutureBuilder<int>(
                future: _getInstalledGamesCount(),
                builder: (context, snapshot) {
                  final value = snapshot.data ?? 0;
                  return _buildStatItem('Installed Games', '$value');
                },
              ),
            ),
            Expanded(
              child: FutureBuilder<int>(
                future: _getTodayPlayTimeSeconds(),
                builder: (context, snapshot) {
                  final seconds = snapshot.data ?? 0;
                  return _buildStatItem('Total Play Time', _formatDuration(Duration(seconds: seconds)));
                },
              )
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatItem(String label, String value) {
    final Map<String, String> helpMessages = {
      'Scheduled Games': 'Shows how many games are scheduled for today.',
      'Pending Rewards': 'Tasks completed by children that need your review. Grant rewards after verification.',
      'Installed Games': 'Total number of games installed on paired child devices.',
      'Total Play Time': 'Sum of all play time for this week across devices.',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 14)),
            GestureDetector(
              onLongPress: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    backgroundColor: const Color(0xFF4A5568),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    content: Text(helpMessages[label] ?? 'Info not available',
                        style: const TextStyle(color: Colors.white)),
                  ),
                );
              },
              onLongPressUp: () {
                Navigator.of(context).pop();
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 4.0),
                child: Icon(Icons.help_outline, color: Colors.orange, size: 16),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmptyActivity() {
    return Column(
      children: [
        Icon(Icons.sports_esports_outlined, size: 48, color: Colors.grey[600]),
        const SizedBox(height: 12),
        Text('No recent gaming activity', style: TextStyle(color: Colors.grey[400], fontSize: 16)),
        const SizedBox(height: 4),
        Text('Gaming activities will appear here once children start playing',
            style: TextStyle(color: Colors.grey[500], fontSize: 14), textAlign: TextAlign.center),
      ],
    );
  }

  Widget _buildActivityList(String filter) {
    if (_pairedDevices.isEmpty) return _buildEmptyActivity();

    return Column(
      children: _pairedDevices.map((device) {
        final childDeviceId = device['childDeviceId'];
        final connectionId = device['id'];
        final childName = _getChildDeviceNameFromSchedule(childDeviceId);

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('game_sessions')
              .doc(connectionId)
              .collection('sessions')
              .where('childDeviceId', isEqualTo: childDeviceId)
              .orderBy('lastUpdateAt', descending: true)
              .limit(10)
              .snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
              return ListTile(
                leading: Icon(Icons.sports_esports_outlined, color: Colors.grey),
                title: Text(childName, style: TextStyle(color: Colors.white)),
                subtitle: Text('No recent gaming activity', style: TextStyle(color: Colors.grey[400])),
              );
            }

            // Collect only "live" sessions (isActive && recent heartbeat)
            final docs = snapshot.data!.docs;
            final now = DateTime.now();

            // Map to deduplicate by packageName (fallback to gameName)
            final Map<String, QueryDocumentSnapshot> uniqueByKey = {};

            for (final doc in docs) {
              final session = doc.data() as Map<String, dynamic>;
              final bool isActive = session['isActive'] == true;
              DateTime? heartbeat;
              if (session['heartbeat'] is Timestamp) {
                heartbeat = (session['heartbeat'] as Timestamp).toDate();
              } else if (session['heartbeat'] is DateTime) {
                heartbeat = session['heartbeat'] as DateTime;
              }

              final bool isLive = isActive && heartbeat != null && now.difference(heartbeat) < Duration(seconds: 60);
              if (!isLive) continue;

              final String key = (session['packageName'] as String?)?.trim().toLowerCase()
                  ?? (session['gameName'] as String?)?.trim().toLowerCase()
                  ?? doc.id;

              // Keep the doc with the most recent heartbeat/lastUpdateAt
              if (!uniqueByKey.containsKey(key)) {
                uniqueByKey[key] = doc;
              } else {
                final existing = uniqueByKey[key]!;
                DateTime? existingHeartbeat;
                final existingSession = existing.data() as Map<String, dynamic>;
                if (existingSession['heartbeat'] is Timestamp) {
                  existingHeartbeat = (existingSession['heartbeat'] as Timestamp).toDate();
                } else if (existingSession['heartbeat'] is DateTime) {
                  existingHeartbeat = existingSession['heartbeat'] as DateTime;
                }
                // Compare heartbeats (or lastUpdateAt fallback)
                final currentHB = heartbeat ?? (session['lastUpdateAt'] is Timestamp ? (session['lastUpdateAt'] as Timestamp).toDate() : null);
                final existingHB = existingHeartbeat ?? (existingSession['lastUpdateAt'] is Timestamp ? (existingSession['lastUpdateAt'] as Timestamp).toDate() : null);

                if (currentHB != null && existingHB != null && currentHB.isAfter(existingHB)) {
                  uniqueByKey[key] = doc;
                }
              }
            }

            if (uniqueByKey.isEmpty) {
              return ListTile(
                leading: Icon(Icons.sports_esports_outlined, color: Colors.grey),
                title: Text(childName, style: TextStyle(color: Colors.white)),
                subtitle: Text('No recent LIVE gaming activity', style: TextStyle(color: Colors.grey[400])),
              );
            }

            // Build tiles from the deduplicated sessions
            return Column(
              children: uniqueByKey.values.map((doc) {
                final session = doc.data() as Map<String, dynamic>;
                final playTime = Duration(seconds: session['totalPlayTimeSeconds'] ?? 0);
                final gameName = session['gameName'] ?? session['packageName'] ?? 'Unknown Game';
                final bool sessionBlockRequested = (session['pauseRequested'] == true);

                return ListTile(
                  leading: Icon(Icons.play_circle, color: sessionBlockRequested ? Colors.orange : Colors.green),
                  title: Text(gameName, style: TextStyle(color: Colors.white)),
                  subtitle: sessionBlockRequested
                      ? Row(
                  )
                      : Text('Player: $childName\nPlay Time: ${_formatDuration(playTime)}', style: TextStyle(color: Colors.grey[300])),
                  trailing: FutureBuilder<DocumentSnapshot>(
                      future: FirebaseFirestore.instance
                          .collection('allowed_games')
                          .doc(connectionId)
                          .get(),
                      builder: (context, allowedSnap) {
                        bool unlockedByKey = false;
                        DateTime? unlockExpiry;
                        if (allowedSnap.hasData && allowedSnap.data != null) {
                          final allowedGames = List<Map<String, dynamic>>.from(
                              (allowedSnap.data!.data() as Map<String, dynamic>)['allowedGames'] ?? []
                          );
                          for (final ag in allowedGames) {
                            if ((ag['packageName'] ?? '').toString().trim() == (session['packageName'] ?? '').toString().trim()) {
                              unlockedByKey = ag['unlockByKey'] == true;
                              if (ag['unlockExpiry'] != null) {
                                unlockExpiry = (ag['unlockExpiry'] as Timestamp).toDate();
                              }
                              break;
                            }
                          }
                        }
                        final isTemporarilyUnlocked = unlockedByKey && unlockExpiry != null && DateTime.now().isBefore(unlockExpiry!);

                        if (isTemporarilyUnlocked) {
                          final expiryStr = unlockExpiry != null
                              ? "Until ${unlockExpiry!.hour.toString().padLeft(2, '0')}:${unlockExpiry!.minute.toString().padLeft(2, '0')}"
                              : "";
                          return Container(
                            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey.shade800,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text('Unlocked by Reward\n$expiryStr', style: TextStyle(color: Colors.white, fontSize: 12)),
                          );
                        } else if (sessionBlockRequested) {
                          return ElevatedButton.icon(
                            icon: const Icon(Icons.hourglass_top, size: 16),
                            label: const Text('Blocking...', style: TextStyle(color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              minimumSize: const Size(0, 36),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: null,
                          );
                        } else {
                          // Normal block button
                          return ElevatedButton.icon(
                            icon: const Icon(Icons.block, size: 16, color: Colors.white),
                            label: const Text('Block', style: TextStyle(color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              minimumSize: const Size(0, 36),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () async {
                              bool blocked = false;
                              try {
                                blocked = await _pauseGamingForSession(connectionId, doc);
                              } catch (e) {
                                print('[BlockButton] _pauseGamingForSession threw: $e');
                                blocked = false;
                              }
                              if (blocked) {
                                await _loadGamingSchedules();
                                if (mounted) setState(() {});
                                return;
                              }

                              // 2. No schedule? Check allowed_games for the session's game and set isGameAllowed to false if true
                              final session = doc.data() as Map<String, dynamic>;
                              final packageName = (session['packageName'] as String?)?.trim();

                              if(packageName != null && packageName.isNotEmpty) {
                                DocumentSnapshot allowedSnap = await FirebaseFirestore.instance
                                    .collection('allowed_games')
                                    .doc(connectionId)
                                    .get();
                                if (allowedSnap.exists && allowedSnap.data() != null) {
                                  Map<String, dynamic> allowedData = allowedSnap.data() as Map<String, dynamic>;
                                  List<dynamic> allowedGames = List.from(allowedData['allowedGames'] ?? []);
                                  bool updated = false;
                                  for(int i = 0; i < allowedGames.length; i++) {
                                    var ag = Map<String, dynamic>.from(allowedGames[i]);
                                    if ((ag['packageName'] ?? '').toString().trim() == packageName && ag['isGameAllowed'] == true) {
                                      ag['isGameAllowed'] = false;
                                      ag['updatedAt'] = Timestamp.fromDate(DateTime.now());
                                      allowedGames[i] = ag;
                                      updated = true;
                                    }
                                  }
                                  if (updated) {
                                    await FirebaseFirestore.instance
                                        .collection('allowed_games')
                                        .doc(connectionId)
                                        .set({
                                      'allowedGames': allowedGames,
                                      'updatedAt': FieldValue.serverTimestamp(),
                                    }, SetOptions(merge: true));
                                  }
                                }
                              }

                              await _loadGamingSchedules();
                              if (mounted) setState(() {});
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('The system will block the game in a minute...'), backgroundColor: Colors.orange),
                              );
                            },
                          );
                        }
                      }
                  ),
                );
              }).toList(),
            );
          },
        );
      }).toList(),
    );
  }

  Future<List<Map<String,String>>> _findAllMatchingSchedules(String connectionId, Map<String, dynamic> session) async {
    final List<Map<String,String>> results = [];
    try {
      final packageName = (session['packageName'] as String?)?.trim();
      final childDeviceId = session['childDeviceId'] as String?;
      final gameName = (session['gameName'] as String?)?.trim();

      if (connectionId.isEmpty) return results;

      String? _matchInDocData(Map<String, dynamic> data, String docId) {
        // search array
        if (data.containsKey('schedules') && data['schedules'] is List) {
          for (var s in List<dynamic>.from(data['schedules'])) {
            if (s is Map) {
              final sChild = s['childDeviceId'] as String?;
              final sPkg = (s['packageName'] as String?)?.trim();
              final sName = (s['gameName'] as String?)?.toString().trim();
              final sId = (s['id'] ?? '').toString();
              if (sChild == childDeviceId && (
                  (packageName != null && sPkg != null && sPkg == packageName) ||
                      (sName != null && gameName != null && sName.toLowerCase() == gameName.toLowerCase())
              )) return sId;
            }
          }
        }

        // root schedule object
        if (data.containsKey('id') && data.containsKey('gameName')) {
          final rootChild = data['childDeviceId'] as String?;
          final rootPkg = (data['packageName'] as String?)?.trim();
          final rootName = (data['gameName'] as String?)?.toString().trim();
          final rootId = (data['id'] ?? '').toString();
          if (rootChild == childDeviceId && (
              (packageName != null && rootPkg != null && rootPkg == packageName) ||
                  (rootName != null && gameName != null && rootName.toLowerCase() == gameName.toLowerCase())
          )) return rootId;
        }

        // numeric/keyed nested objects
        for (final key in data.keys) {
          final val = data[key];
          if (val is Map) {
            final nested = Map<String, dynamic>.from(val);
            final nestedChild = nested['childDeviceId'] as String?;
            final nestedPkg = (nested['packageName'] as String?)?.trim();
            final nestedName = (nested['gameName'] as String?)?.toString().trim();
            final nestedId = (nested['id'] ?? '').toString();
            if (nestedChild == childDeviceId && (
                (packageName != null && nestedPkg != null && nestedPkg == packageName) ||
                    (nestedName != null && gameName != null && nestedName.toLowerCase() == gameName.toLowerCase())
            )) return nestedId;
          }
        }
        return null;
      }

      // 1) Check intended doc first
      final schedRef = FirebaseFirestore.instance.collection('gaming_scheduled').doc(connectionId);
      final schedSnap = await schedRef.get();
      if (schedSnap.exists && schedSnap.data() != null) {
        final data = Map<String, dynamic>.from(schedSnap.data() as Map<String, dynamic>);
        // collect all matches in this doc
        if (data.containsKey('schedules') && data['schedules'] is List) {
          for (var s in List<dynamic>.from(data['schedules'])) {
            if (s is Map) {
              final sChild = s['childDeviceId'] as String?;
              final sPkg = (s['packageName'] as String?)?.trim();
              final sName = (s['gameName'] as String?)?.toString().trim();
              final sId = (s['id'] ?? '').toString();
              if (sChild == childDeviceId && (
                  (packageName != null && sPkg != null && sPkg == packageName) ||
                      (sName != null && gameName != null && sName.toLowerCase() == gameName.toLowerCase())
              )) {
                results.add({'docId': connectionId, 'scheduleId': sId});
              }
            }
          }
        } else {
          final maybe = _matchInDocData(data, connectionId);
          if (maybe != null) results.add({'docId': connectionId, 'scheduleId': maybe});
        }
      }

      // 2) Fallback: scan other documents (limit to reasonable number)
      if (results.isEmpty) {
        final querySnap = await FirebaseFirestore.instance.collection('gaming_scheduled').limit(50).get();
        for (var doc in querySnap.docs) {
          final data = doc.data() as Map<String, dynamic>?;
          if (data == null) continue;
          if (data.containsKey('schedules') && data['schedules'] is List) {
            for (var s in List<dynamic>.from(data['schedules'])) {
              if (s is Map) {
                final sChild = s['childDeviceId'] as String?;
                final sPkg = (s['packageName'] as String?)?.trim();
                final sName = (s['gameName'] as String?)?.toString().trim();
                final sId = (s['id'] ?? '').toString();
                if (sChild == childDeviceId && (
                    (packageName != null && sPkg != null && sPkg == packageName) ||
                        (sName != null && gameName != null && sName.toLowerCase() == gameName.toLowerCase())
                )) {
                  results.add({'docId': doc.id, 'scheduleId': sId});
                }
              }
            }
          } else {
            final maybe = _matchInDocData(Map<String, dynamic>.from(data), doc.id);
            if (maybe != null) results.add({'docId': doc.id, 'scheduleId': maybe});
          }
        }
      }

      return results;
    } catch (e, st) {
      print('[_findAllMatchingSchedules] error: $e\n$st');
      return results;
    }
  }

  Future<bool> _pauseGamingForSession(String connectionId, QueryDocumentSnapshot sessionDoc) async {
    try {
      final session = sessionDoc.data() as Map<String, dynamic>;
      print('[pause-session] called for connection=$connectionId sessionDoc=${sessionDoc.id}');

      if (connectionId.isEmpty) return false;

      final matches = await _findAllMatchingSchedules(connectionId, session);

      if (matches.isNotEmpty) {
        bool anyPaused = false;
        final Map<String, List<String>> byDoc = {};
        for (var m in matches) {
          final docId = m['docId']!;
          final sId = m['scheduleId']!;
          byDoc.putIfAbsent(docId, () => []).add(sId);
        }

        for (final docId in byDoc.keys) {
          final List<String> scheduleIds = byDoc[docId]!;
          for (final sId in scheduleIds) {
            final paused = await _pauseSchedule(sId, connectionId: docId);
            if (paused) {
              anyPaused = true;
            } else {
              print('[pause-session] failed to pause schedule $sId in doc $docId');
            }
          }
          // refresh allowed_games for that docId (important to immediately block the game)
          await _updateAllowedGamesFromSchedules(connectionId: docId);
        }

        // Immediately mark session doc so parent UI reflects the pause (and to give the player a signal)
        if (anyPaused) {
          try {
            final sessionRef = FirebaseFirestore.instance
                .collection('game_sessions')
                .doc(connectionId)
                .collection('sessions')
                .doc(sessionDoc.id);

            DateTime now = DateTime.now();
            DateTime? launchedAt;
            if (session['launchedAt'] is Timestamp) launchedAt = (session['launchedAt'] as Timestamp).toDate();
            else if (session['launchedAt'] is DateTime) launchedAt = session['launchedAt'] as DateTime;

            int finalPlaySeconds = 0;
            if (launchedAt != null) {
              finalPlaySeconds = now.difference(launchedAt).inSeconds;
            } else {
              finalPlaySeconds = session['totalPlayTimeSeconds'] is int
                  ? session['totalPlayTimeSeconds'] as int
                  : int.tryParse(session['totalPlayTimeSeconds']?.toString() ?? '0') ?? 0;
            }

            await sessionRef.update({
              // keep the session live flag untouched if you don't want to force-end immediately
              // 'isActive': false, <-- don't force end here; instead signal request
              'pauseRequested': true,
              'pauseRequestedAt': Timestamp.fromDate(now),
              'pauseEtaSeconds': PAUSE_ESTIMATED_SECONDS,
              'lastUpdateAt': FieldValue.serverTimestamp(),
              'showAsRecent': true,
              // keep the debug flag for final end if you will mark ended later
              'pauseRequestedBy': 'parent',
            });

            print('[pause-session] marked session ${sessionDoc.id} as pauseRequested');
          } catch (e, st) {
            print('[pause-session] error updating session doc after pausing schedules: $e\n$st');
          }
        }

        // refresh UI (parent view)
        await _loadGamingSchedules();
        if (mounted) setState(() {});
        if (anyPaused && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please wait a minute.'), backgroundColor: Colors.orange));
        return anyPaused;
      }

      // fallback: end the session doc if no schedule found
      final sessionRef = FirebaseFirestore.instance
          .collection('game_sessions')
          .doc(connectionId)
          .collection('sessions')
          .doc(sessionDoc.id);

      DateTime now = DateTime.now();
      DateTime? launchedAt;
      if (session['launchedAt'] is Timestamp) launchedAt = (session['launchedAt'] as Timestamp).toDate();
      else if (session['launchedAt'] is DateTime) launchedAt = session['launchedAt'] as DateTime;
      int finalPlaySeconds = session['totalPlayTimeSeconds'] ?? 0;
      if (launchedAt != null) finalPlaySeconds = now.difference(launchedAt).inSeconds;

      await sessionRef.update({
        'isActive': false,
        'endedAt': Timestamp.fromDate(now),
        'totalPlayTimeSeconds': finalPlaySeconds,
        'lastUpdateAt': FieldValue.serverTimestamp(),
        'showAsRecent': true,
      });

      await _loadGamingSchedules();
      await _updateAllowedGamesFromSchedules(connectionId: connectionId);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ended active session (no schedule found)'), backgroundColor: Colors.orange));
      }
      return true;
    } catch (e, st) {
      print('[pause-session] unexpected error: $e\n$st');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error pausing session'), backgroundColor: Colors.red));
      return false;
    }
  }

  Future<void> _setIsGameAllowed(String connectionId, String packageName, bool allow) async {
    try {
      // 1. Get the existing allowed_games doc
      final docRef = FirebaseFirestore.instance.collection('allowed_games').doc(connectionId);
      final docSnap = await docRef.get();
      if (!docSnap.exists || docSnap.data() == null) return;

      final data = docSnap.data() as Map<String, dynamic>;
      List<dynamic> allowedGames = List.from(data['allowedGames'] ?? []);
      bool updated = false;

      for (int i = 0; i < allowedGames.length; i++) {
        if ((allowedGames[i]['packageName'] ?? '') == packageName) {
          allowedGames[i]['isGameAllowed'] = allow;
          allowedGames[i]['updatedAt'] = Timestamp.fromDate(DateTime.now());
          updated = true;
          break;
        }
      }

      if (updated) {
        await docRef.set({
          'allowedGames': allowedGames,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      print('Failed to update isGameAllowed: $e');
    }
  }

  Widget _buildWeeklyReportCard() {
    return FutureBuilder<Map<String, int>>(
      future: getWeeklyGamePlayTotals(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return _buildCard(
            'Weekly Gaming Report',
            Icons.calendar_today,
            Center(child: CircularProgressIndicator(color: Color(0xFFE07A39))),
          );
        }
        final gameTotals = snapshot.data!;
        if (gameTotals.isEmpty) {
          return _buildCard(
            'Weekly Gaming Report',
            Icons.calendar_today,
            Center(child: Text('No gaming sessions this week', style: TextStyle(color: Colors.grey[400]))),
          );
        }
        final totalSeconds = gameTotals.values.fold(0, (a, b) => a + b);

        // Show bar for each game (like design in image 2)
        final widgets = gameTotals.entries.map((entry) {
          final percent = (totalSeconds == 0) ? 0.0 : entry.value / totalSeconds;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 0),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  child: Icon(Icons.videogame_asset, color: Colors.white),
                  backgroundColor: Colors.orange,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.key, style: TextStyle(color: Colors.white)),
                      LinearProgressIndicator(
                        value: percent,
                        minHeight: 12,
                        backgroundColor: Colors.grey[300],
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                      ),
                      Text('${_formatDuration(Duration(seconds: entry.value))}', style: TextStyle(color: Colors.grey[300])),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList();

        return _buildCard(
          'Weekly Gaming Report',
          Icons.calendar_today,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total Play Time: ${_formatDuration(Duration(seconds: totalSeconds))}',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              SizedBox(height: 12),
              ...widgets,
            ],
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes}m';
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }

  Widget _buildTasksList() {
    if (_pairedDevices.isEmpty) {
      return Center(child: Text('No paired child devices found', style: TextStyle(color: Colors.grey[400])));
    }
    return ListView(
      children: _pairedDevices.map((device) {
        final childDeviceId = device['childDeviceId'];
        final connectionId = device['id']; // The document ID for task_and_rewards

        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('task_and_rewards')
              .doc(connectionId)
              .snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data!.data() == null) {
              return ListTile(
                title: Text(_getChildDeviceNameFromSchedule(childDeviceId), style: TextStyle(color: Colors.white)),
                subtitle: Text('No tasks', style: TextStyle(color: Colors.grey[400])),
              );
            }
            final data = snapshot.data!.data() as Map<String, dynamic>;
            final tasks = (data['tasks'] ?? [])
                .where((t) => t['childDeviceId'] == childDeviceId)
                .map((t) => Map<String, dynamic>.from(t))
                .toList();

            if (tasks.isEmpty) {
              return ListTile(
                title: Text(_getChildDeviceNameFromSchedule(childDeviceId), style: TextStyle(color: Colors.white)),
                subtitle: Text('No tasks', style: TextStyle(color: Colors.grey[400])),
              );
            }

            return ExpansionTile(
              title: Text(_getChildDeviceNameFromSchedule(childDeviceId), style: TextStyle(color: Colors.white)),
              children: tasks.map<Widget>((task) => ListTile(
                title: Text(task['task'] ?? '', style: TextStyle(color: Colors.white)),
                subtitle: Text('Reward: ${task['reward']['points']} pts', style: TextStyle(color: Colors.orange)),
                trailing: Builder(
                  builder: (context) {
                    final status = task['reward']['status'];
                    if (status == 'verify') {
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Needs Verification',
                            style: TextStyle(
                              color: Colors.orange,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              minimumSize: Size(0, 32),
                            ),
                            child: Text('Grant Reward', style: TextStyle(fontSize: 12)),
                            onPressed: () async {
                              await _grantReward(
                                connectionId,
                                childDeviceId,
                                task,
                              );
                              // No need to call setState() - StreamBuilder will rebuild automatically
                            },
                          ),
                        ],
                      );
                    }
                    return Text(
                      status ?? '',
                      style: TextStyle(
                        color: status == 'pending' ? Colors.red : Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    );
                  },
                ),
              )).toList(), // <-- THIS FIXES THE ERROR
            );
          },
        );
      }).toList(),
    );
  }

  Widget _buildWeeklySessionDesign(Map<String, dynamic> session) {
    final gameName = session['gameName'] ?? session['packageName'] ?? 'Unknown Game';
    final playTimeSeconds = session['totalPlayTimeSeconds'] ?? 0;
    final isActive = session['isActive'] == true;

    // For demo, use fixed image, replace with your real game icon source
    final imageProvider = AssetImage('assets/game_icon.png'); // or NetworkImage(url) if you save url in Firestore

    // Set colors based on status
    final barColor = isActive ? Colors.orange : Colors.blue;

    // Set progress value (e.g., playTime as % of max for week)
    // For demo, maxPlayTime = 2 hours, adjust as needed
    final double maxPlayTime = 2 * 60 * 60.0;
    final double percent = (playTimeSeconds / maxPlayTime).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 0),
      child: Row(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundImage: imageProvider,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: LinearProgressIndicator(
              value: percent,
              minHeight: 12,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _removeNullFieldsFromTasks(List<Map<String, dynamic>> tasks) {
    return tasks.map((task) {
      return Map<String, dynamic>.fromEntries(
          task.entries.where((entry) => entry.value != null)
      );
    }).toList();
  }

  Map<String, dynamic> removeNullFields(Map<String, dynamic> map) {
    return Map.fromEntries(map.entries.where((e) => e.value != null));
  }

  Future<void> _grantReward(String connectionId, String childDeviceId, Map<String, dynamic> task) async {
    print('[DEBUG] Granting reward for connectionId: $connectionId, childDeviceId: $childDeviceId, task: $task');
    final points = task['reward']['points'];
    final taskId = task['task'];

    final docRef = FirebaseFirestore.instance.collection('accumulated_points').doc(connectionId);
    final tasksRef = FirebaseFirestore.instance.collection('task_and_rewards').doc(connectionId);

    try {
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final snapshot = await transaction.get(docRef);
        print('[DEBUG] accumulated_points snapshot.exists: ${snapshot.exists}');
        print('[DEBUG] accumulated_points snapshot.data(): ${snapshot.data()}');

        final tasksSnap = await transaction.get(tasksRef);
        print('[DEBUG] task_and_rewards snapshot.exists: ${tasksSnap.exists}');
        print('[DEBUG] task_and_rewards snapshot.data(): ${tasksSnap.data()}');

        int currentPoints = 0;
        if (snapshot.exists && snapshot.data() != null) {
          currentPoints = snapshot.data()!['points'] ?? 0;
        }

        List<Map<String, dynamic>> tasksList = [];
        if (tasksSnap.exists && tasksSnap.data() != null) {
          final data = Map<String, dynamic>.from(tasksSnap.data()!);
          tasksList = List<Map<String, dynamic>>.from(data['tasks'] ?? []);
        }

        print('[DEBUG] tasksList before update: $tasksList');
        print('[DEBUG] tasksList type: ${tasksList.runtimeType}');
        for (var i = 0; i < tasksList.length; i++) {
          print('[DEBUG] tasksList[$i]: ${tasksList[i]} type: ${tasksList[i].runtimeType}');
        }

        // Update the status to "granted" for the correct task
        for (var t in tasksList) {
          if (t['task'] == taskId && t['childDeviceId'] == childDeviceId && t['reward']['status'] == 'verify') {
            // Make sure reward is a plain map
            t['reward'] = Map<String, dynamic>.from(t['reward']);
            t['reward']['status'] = 'granted';
            // Use a normal DateTime for nested grantedAt
            t['reward']['grantedAt'] = DateTime.now();
          }
        }

        // Deep clean all tasks and their nested maps
        List<Map<String, dynamic>> cleanTasksList = tasksList.map((task) {
          final newTask = Map<String, dynamic>.from(task);
          if (newTask['reward'] != null) {
            newTask['reward'] = Map<String, dynamic>.from(newTask['reward']);
            newTask['reward'].removeWhere((k, v) => v == null);
          }
          newTask.removeWhere((k, v) => v == null);
          return newTask;
        }).toList();

        print('[DEBUG] cleanTasksList to Firestore: $cleanTasksList');

        transaction.set(docRef, {
          'childDeviceId': childDeviceId,
          'parentDeviceId': _deviceId,
          'points': currentPoints + (points ?? 0),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        transaction.set(tasksRef, {
          'tasks': cleanTasksList,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
      print('[DEBUG] Transaction completed successfully');
      await _deleteGrantedTasksAfterDelay(connectionId, childDeviceId, taskId); 
    } catch (e, stack) {
      print('[ERROR] Firestore transaction error: $e');
      print('[ERROR] Stacktrace: $stack');
    }
  }

  Future<void> _deleteGrantedTasksAfterDelay(String connectionId, String childDeviceId, String taskId) async {
    await Future.delayed(const Duration(seconds: 10));
    final tasksRef = FirebaseFirestore.instance.collection('task_and_rewards').doc(connectionId);

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final tasksSnap = await transaction.get(tasksRef);
      if (!tasksSnap.exists || tasksSnap.data() == null) return;

      final data = Map<String, dynamic>.from(tasksSnap.data()!);
      List<Map<String, dynamic>> tasksList = List<Map<String, dynamic>>.from(data['tasks'] ?? []);

      // Remove the granted task(s)
      tasksList.removeWhere((t) =>
      t['task'] == taskId &&
          t['childDeviceId'] == childDeviceId &&
          t['reward'] != null &&
          t['reward']['status'] == 'granted'
      );

      transaction.set(tasksRef, {
        'tasks': tasksList,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });

    print('[DEBUG] Deleted granted task for $taskId after delay');
  }

  Widget _buildControlTile(String title, String description, IconData icon, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        tileColor: const Color(0xFF4A5568),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFE07A39).withOpacity(0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: const Color(0xFFE07A39), size: 24),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
        subtitle: Text(description, style: TextStyle(color: Colors.grey[400], fontSize: 14)),
        trailing: Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey[400]),
        onTap: onTap,
      ),
    );
  }

  int _getScheduledGamesCount() {
    if (_gamingSchedules.isEmpty) return 0;

    DateTime today = DateTime.now();
    return _gamingSchedules.where((schedule) {
      final scheduledDate = (schedule['scheduledDate'] as Timestamp).toDate();
      final isToday = scheduledDate.year == today.year &&
          scheduledDate.month == today.month &&
          scheduledDate.day == today.day;

      // Count both "active" and "scheduled" for today (not past)
      final status = (schedule['status'] ?? '').toString().toLowerCase();
      return isToday &&
          (status == 'active' || (status == 'scheduled' && !_isSchedulePast(schedule)));
    }).length;
  }

  Future<int> _getPendingRewardsCount() async {
    int total = 0;
    for (final device in _pairedDevices) {
      final connectionId = device['id'];
      if (connectionId == null) continue;
      DocumentSnapshot docSnap = await FirebaseFirestore.instance
          .collection('task_and_rewards')
          .doc(connectionId)
          .get();
      if (!docSnap.exists || docSnap.data() == null) continue;
      final data = docSnap.data() as Map<String, dynamic>;
      if (data['tasks'] == null) continue;
      for (var t in data['tasks']) {
        if (t['reward'] != null &&
            (t['reward']['status'] == 'pending' || t['reward']['status'] == 'verify')) {
          total++;
        }
      }
    }
    return total;
  }

  Future<List<Map<String, dynamic>>> fetchTasksAndRewardsForChild(String connectionId, String childDeviceId) async {
    DocumentSnapshot docSnap = await FirebaseFirestore.instance
        .collection('task_and_rewards')
        .doc(connectionId)
        .get();

    if (!docSnap.exists || docSnap.data() == null) return [];

    final data = docSnap.data() as Map<String, dynamic>;
    if (data['tasks'] == null) return [];

    // Filter tasks for this child device
    List<Map<String, dynamic>> tasksForChild = [];
    for (var t in data['tasks']) {
      if (t['childDeviceId'] == childDeviceId) {
        tasksForChild.add(Map<String, dynamic>.from(t));
      }
    }
    return tasksForChild;
  }

  Future<int> _getInstalledGamesCount() async {
    try {
      // Use the correct document ID for the device you care about.
      // For example, use _connectionId or the specific deviceId:
      String deviceDocId = _connectionId ?? '';
      if (deviceDocId.isEmpty) return 0;

      // If your installed_games doc uses device ID as key, strip any prefix if needed
      if (deviceDocId.startsWith('child_android_')) {
        deviceDocId = deviceDocId.replaceFirst('child_android_', '');
      }

      DocumentSnapshot snapshot = await FirebaseFirestore.instance
          .collection('installed_games')
          .doc(deviceDocId)
          .get();

      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>?;
        if (data != null && data['games'] is List) {
          return (data['games'] as List).length;
        } else if (data != null && data['totalGames'] is int) {
          return data['totalGames'] as int;
        }
      }
      return 0;
    } catch (e) {
      print('Error getting installed games count: $e');
      return 0;
    }
  }

  Future<String> _getTotalWeeklyPlayTime() async {
    final sessions = await _getWeeklySessions();
    int totalSeconds = 0;
    for (var session in sessions) {
      final raw = session['totalPlayTimeSeconds'];
      if (raw is int) {
        totalSeconds += raw;
      } else if (raw is double) {
        totalSeconds += raw.toInt();
      } else if (raw is num) {
        totalSeconds += raw.toInt();
      } else if (raw != null) {
        try {
          totalSeconds += int.parse(raw.toString());
        } catch (_) {}
      }
    }
    if (totalSeconds == 0) return 'No Play Time';
    return _formatDuration(Duration(seconds: totalSeconds));
  }
  // Action methods
  void _showNotifications() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Notifications feature coming soon!'),
        backgroundColor: const Color(0xFF4A5568),
      ),
    );
  }

  void _addNewSchedule() {
    if (_pairedDevices.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No paired devices found. Please pair a child device first.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    if (_gamingSchedules.length >= MAX_SCHEDULES_PER_CONNECTION) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Maximum of $MAX_SCHEDULES_PER_CONNECTION gaming schedules allowed per connection.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    // ✅ Store context reference before async operations
    final BuildContext dialogContext = context;
    final ScaffoldMessengerState? scaffoldMessenger =
    mounted ? ScaffoldMessenger.of(context) : null;

    showDialog(
      context: dialogContext,
      builder: (context) => _AddScheduleDialog(
        pairedDevices: _pairedDevices,
        connectionId: _connectionId!,
        maxSchedules: MAX_SCHEDULES_PER_CONNECTION,
        currentScheduleCount: _gamingSchedules.length,
        onScheduleAdded: (schedule) async {
          try {
            bool success = await addGamingSchedule(
              childDeviceId: schedule['childDeviceId'],
              gameName: schedule['gameName'],
              packageName: schedule['packageName'],
              scheduledDate: schedule['scheduledDate'],
              startTime: schedule['startTime'],
              endTime: schedule['endTime'],
              durationMinutes: schedule['durationMinutes'],
              tasks: schedule['tasks'],
              isRecurring: schedule['isRecurring'] ?? false,
              recurringDays: schedule['recurringDays'] ?? [],
            );

            // ✅ Use stored scaffoldMessenger reference and check if widget is still mounted
            if (mounted && scaffoldMessenger != null) {
              if (success) {
                scaffoldMessenger.showSnackBar(
                  const SnackBar(
                    content: Text('Gaming schedule added successfully!'),
                    backgroundColor: Colors.green,
                  ),
                );
              } else {
                scaffoldMessenger.showSnackBar(
                  const SnackBar(
                    content: Text('Failed to add gaming schedule. Cannot exceed maximum limit or connection error.'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            } else {
              print('Widget disposed or scaffoldMessenger null - schedule operation completed but no UI feedback');
            }
          } catch (e) {
            print('Error in onScheduleAdded callback: $e');
            if (mounted && scaffoldMessenger != null) {
              scaffoldMessenger.showSnackBar(
                SnackBar(
                  content: Text('Error adding schedule: $e'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        },
      ),
    );
  }

  void _editSchedule(Map<String, dynamic> schedule) {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => _AddScheduleDialog(
        pairedDevices: _pairedDevices,
        connectionId: _connectionId!,
        maxSchedules: MAX_SCHEDULES_PER_CONNECTION,
        currentScheduleCount: _gamingSchedules.length,
        existingSchedule: schedule,
        onScheduleAdded: (updatedSchedule) async {
          try {
            // Update in database
            bool success = await _updateScheduleInDatabase(schedule, updatedSchedule);

            // ✅ Check if widget is still mounted before using context
            if (!mounted) {
              print('Widget is no longer mounted, skipping SnackBar');
              return;
            }

            try {
              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Gaming schedule updated successfully!'),
                    backgroundColor: Colors.green,
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Failed to update gaming schedule. Please try again.'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            } catch (contextError) {
              print('Context error when showing SnackBar: $contextError');
            }
          } catch (e) {
            print('Error in edit callback: $e');
            if (mounted) {
              try {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Error updating schedule: $e'),
                    backgroundColor: Colors.red,
                  ),
                );
              } catch (contextError) {
                print('Context error when showing error SnackBar: $contextError');
              }
            }
          }
        },
      ),
    );
  }

  void _deleteScheduleFromList(Map<String, dynamic> schedule) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D3748),
        title: const Text('Delete Schedule', style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to delete the gaming schedule for "${schedule['gameName']}"?',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);

              // Use the schedule ID from the schedule
              String scheduleId = schedule['id'];

              // Delete from database
              bool success = await deleteGamingSchedule(scheduleId);

              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Gaming schedule deleted successfully!'),
                    backgroundColor: Colors.green,
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Failed to delete gaming schedule. Please try again.'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _startScheduleTimer() {

    _autoUpdateScheduleStatuses();
    _scheduleTimer?.cancel(); // Cancel existing timer if any

    _scheduleTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      // ✅ CHECK IF WIDGET IS STILL MOUNTED
      if (!mounted) {
        timer.cancel();
        return;
      }

      await _autoUpdateScheduleStatuses();

      // Update UI for real-time status
      setState(() {
        // This will trigger a rebuild to update remaining time displays
      });
    });
  }

  Future<void> _autoUpdateScheduleStatuses() async {
    if (_connectionId == null || _connectionId!.isEmpty) return;
    DocumentSnapshot doc = await FirebaseFirestore.instance
        .collection('gaming_scheduled')
        .doc(_connectionId!)
        .get();

    if (!doc.exists) return;

    final data = doc.data() as Map<String, dynamic>?;
    if (data == null || data['schedules'] == null) return;

    List<dynamic> schedules = List.from(data['schedules']);
    DateTime now = DateTime.now();
    bool anyChanges = false;

    for (var schedule in schedules) {
      try {
        if (schedule['scheduledDate'] == null || schedule['startTime'] == null || schedule['endTime'] == null) continue;

        final scheduledDate = (schedule['scheduledDate'] as Timestamp).toDate();
        final startTimeParts = schedule['startTime'].toString().split(':');
        final endTimeParts = schedule['endTime'].toString().split(':');
        final startDateTime = DateTime(
          scheduledDate.year,
          scheduledDate.month,
          scheduledDate.day,
          int.parse(startTimeParts[0]),
          int.parse(startTimeParts[1]),
        );
        final endDateTime = DateTime(
          scheduledDate.year,
          scheduledDate.month,
          scheduledDate.day,
          int.parse(endTimeParts[0]),
          int.parse(endTimeParts[1]),
        );

        // Handle end time that rolls to next day
        final adjustedEndDateTime = endDateTime.isBefore(startDateTime) ? endDateTime.add(const Duration(days: 1)) : endDateTime;

        final nowIsDuring = now.isAfter(startDateTime) && now.isBefore(adjustedEndDateTime);
        final nowIsAfter = now.isAfter(adjustedEndDateTime);

        final statusRaw = (schedule['status'] ?? '').toString().toLowerCase();
        final isPaused = statusRaw == 'paused';
        final isCompleted = statusRaw == 'completed' || statusRaw == 'cancelled';

        // Respect explicit paused/completed states:
        if (isPaused) {
          // If paused but schedule already ended, mark completed.
          if (nowIsAfter) {
            if (schedule['status'] != 'completed' || schedule['isActive'] == true) {
              schedule['status'] = 'completed';
              schedule['isActive'] = false;
              schedule['updatedAt'] = Timestamp.fromDate(now);
              anyChanges = true;
            }
          }
          // Otherwise leave it paused (do not auto-set active/scheduled)
          continue;
        }

        if (isCompleted) {
          // Completed/cancelled stays completed (no re-activation)
          // If ended and not marked completed yet, ensure isActive false
          if (nowIsAfter && schedule['isActive'] == true) {
            schedule['isActive'] = false;
            schedule['updatedAt'] = Timestamp.fromDate(now);
            anyChanges = true;
          }
          continue;
        }

        // Normal auto-state transitions for schedules that are not paused/completed
        if (nowIsDuring) {
          // Schedule should be active now
          if (schedule['status'] != 'active' || schedule['isActive'] != true) {
            schedule['status'] = 'active';
            schedule['isActive'] = true;
            schedule['updatedAt'] = Timestamp.fromDate(now);
            anyChanges = true;
          }
        } else if (nowIsAfter) {
          // Schedule ended -> mark completed
          if (schedule['status'] != 'completed' || schedule['isActive'] != false) {
            schedule['status'] = 'completed';
            schedule['isActive'] = false;
            schedule['updatedAt'] = Timestamp.fromDate(now);
            anyChanges = true;
          }
        } else {
          // Upcoming / scheduled
          if (schedule['status'] != 'scheduled' || schedule['isActive'] != true) {
            schedule['status'] = 'scheduled';
            schedule['isActive'] = true;
            schedule['updatedAt'] = Timestamp.fromDate(now);
            anyChanges = true;
          }
        }
      } catch (e) {
        print('[autoUpdate] skipped schedule due to error: $e');
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

      await _updateAllowedGamesFromSchedules();
    }
  }

  int _getRemainingPauseSeconds(Map<String, dynamic> item) {
    try {
      final pr = item['pauseRequestedAt'];
      final int eta = (item['pauseEtaSeconds'] is int) ? item['pauseEtaSeconds'] as int : PAUSE_ESTIMATED_SECONDS;
      DateTime req;
      if (pr is Timestamp) req = pr.toDate();
      else if (pr is DateTime) req = pr;
      else if (pr is String) req = DateTime.tryParse(pr) ?? DateTime.now();
      else return 0;
      final rem = eta - DateTime.now().difference(req).inSeconds;
      return rem > 0 ? rem : 0;
    } catch (e) {
      return 0;
    }
  }

  String _formatRemaining(int seconds) {
    if (seconds <= 0) return 'Pending';
    final d = Duration(seconds: seconds);
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  bool _isScheduleActive(Map<String, dynamic> schedule) {
    try {
      final scheduledDate = (schedule['scheduledDate'] as Timestamp).toDate();
      final now = DateTime.now();

      // Check if it's the same date
      if (scheduledDate.year != now.year ||
          scheduledDate.month != now.month ||
          scheduledDate.day != now.day) {
        return false;
      }

      // Parse start and end times
      final startTimeParts = schedule['startTime'].toString().split(':');
      final endTimeParts = schedule['endTime'].toString().split(':');

      final startHour = int.parse(startTimeParts[0]);
      final startMinute = int.parse(startTimeParts[1]);
      final endHour = int.parse(endTimeParts[0]);
      final endMinute = int.parse(endTimeParts[1]);

      // Create DateTime objects for comparison
      final startDateTime = DateTime(now.year, now.month, now.day, startHour, startMinute);
      final endDateTime = DateTime(now.year, now.month, now.day, endHour, endMinute);

      // Handle case where end time is next day (past midnight)
      final adjustedEndDateTime = endDateTime.isBefore(startDateTime)
          ? endDateTime.add(const Duration(days: 1))
          : endDateTime;

      return now.isAfter(startDateTime) && now.isBefore(adjustedEndDateTime);
    } catch (e) {
      print('Error checking schedule active status: $e');
      return false;
    }
  }

  String _getRemainingTime(Map<String, dynamic> schedule) {
    if (!_isScheduleActive(schedule)) return '';

    try {
      final now = DateTime.now();
      final endTimeParts = schedule['endTime'].toString().split(':');
      final endHour = int.parse(endTimeParts[0]);
      final endMinute = int.parse(endTimeParts[1]);

      final endDateTime = DateTime(now.year, now.month, now.day, endHour, endMinute);
      final adjustedEndDateTime = endDateTime.isBefore(now)
          ? endDateTime.add(const Duration(days: 1))
          : endDateTime;

      final difference = adjustedEndDateTime.difference(now);
      final hours = difference.inHours;
      final minutes = difference.inMinutes % 60;
      final seconds = difference.inSeconds % 60;

      if (hours > 0) {
        return '${hours}h ${minutes}m ${seconds}s remaining';
      } else {
        return '${minutes}m ${seconds}s remaining';
      }
    } catch (e) {
      return '';
    }
  }

// Helper method to get time until schedule starts
  String _getTimeUntilStart(Map<String, dynamic> schedule) {
    try {
      final scheduledDate = (schedule['scheduledDate'] as Timestamp).toDate();
      final now = DateTime.now();

      final startTimeParts = schedule['startTime'].toString().split(':');
      final startHour = int.parse(startTimeParts[0]);
      final startMinute = int.parse(startTimeParts[1]);

      final startDateTime = DateTime(scheduledDate.year, scheduledDate.month, scheduledDate.day, startHour, startMinute);

      if (startDateTime.isBefore(now)) return '';

      final difference = startDateTime.difference(now);
      final days = difference.inDays;
      final hours = difference.inHours % 24;
      final minutes = difference.inMinutes % 60;

      if (days > 0) {
        return 'Starts in ${days}d ${hours}h ${minutes}m';
      } else if (hours > 0) {
        return 'Starts in ${hours}h ${minutes}m';
      } else {
        return 'Starts in ${minutes}m';
      }
    } catch (e) {
      return '';
    }
  }

// Helper method to check if schedule is past/completed
  bool _isSchedulePast(Map<String, dynamic> schedule) {
    try {
      final scheduledDate = (schedule['scheduledDate'] as Timestamp).toDate();
      final now = DateTime.now();

      final endTimeParts = schedule['endTime'].toString().split(':');
      final endHour = int.parse(endTimeParts[0]);
      final endMinute = int.parse(endTimeParts[1]);

      final endDateTime = DateTime(scheduledDate.year, scheduledDate.month, scheduledDate.day, endHour, endMinute);

      return endDateTime.isBefore(now);
    } catch (e) {
      return false;
    }
  }

  void _logout() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Logout'),
          content: const Text('Are you sure you want to logout?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushReplacementNamed(context, '/welcome');
              },
              child: const Text('Logout'),
            ),
          ],
        );
      },
    );
  }

  void _addNewChild() async {
    // Get device info before navigating
    final deviceData = await _getDeviceId();

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (context) => ParentDevicePage(
          initialDeviceId: deviceData['deviceId'] as String,
          initialDeviceInfo: deviceData['deviceInfo'] as Map<String, dynamic>,
        ),
      ),
          (route) => false,
    );
  }
}


class _AddScheduleDialog extends StatefulWidget {
  final List<Map<String, dynamic>> pairedDevices;
  final String connectionId; // <--- ADD THIS
  final Function(Map<String, dynamic>) onScheduleAdded;
  final Map<String, dynamic>? existingSchedule;
  final int maxSchedules;
  final int currentScheduleCount;

  const _AddScheduleDialog({
    super.key, // Use Key? key and super(key: key)
    required this.pairedDevices,
    required this.connectionId, // <--- ADD THIS
    required this.onScheduleAdded,
    required this.maxSchedules,
    required this.currentScheduleCount,
    this.existingSchedule,
  });

  @override
  _AddScheduleDialogState createState() => _AddScheduleDialogState();
}

class _AddScheduleDialogState extends State<_AddScheduleDialog> {
  final _formKey = GlobalKey<FormState>();

  // Predefined tasks
  final List<String> _predefinedTasks = [
    'Wash dishes',
    'Clean room',
    'Take out trash',
    'Feed pets',
    'Do homework',
    // ...add more as needed
  ];

  // Points options
  final List<int> _pointsOptions = [5, 10, 15, 20];

  // List of tasks for this schedule. Each entry is a Map with name and points.
  List<Map<String, dynamic>> _tasks = [
    {'name': null, 'custom': '', 'points': null}
  ];

  String? _selectedChildDeviceId;
  DateTime _selectedDate = DateTime.now();
  String? _selectedGameName;
  String? _selectedGamePackageName;
  List<Map<String, String>> _installedGames = [];
  bool _isLoadingGames = false;
  TimeOfDay _startTime = TimeOfDay.now();
  TimeOfDay _endTime = TimeOfDay(hour: (TimeOfDay.now().hour + 1) % 24, minute: TimeOfDay.now().minute);
  bool _isRecurring = false;
  List<int> _selectedDays = [];
  final List<String> _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    if (widget.existingSchedule != null) {
      final s = widget.existingSchedule!;
      _selectedChildDeviceId = s['childDeviceId'];
      _selectedDate = (s['scheduledDate'] as Timestamp).toDate();
      _selectedGameName = s['gameName'];
      _selectedGamePackageName = s['packageName'];
      _startTime = _parseTimeOfDay(s['startTime']);
      _endTime = _parseTimeOfDay(s['endTime']);
      _isRecurring = s['isRecurring'] ?? false;
      _selectedDays = (s['recurringDays'] ?? []).cast<int>();
      // Tasks:
      if (s['tasks'] != null && s['tasks'] is List) {
        _tasks = (s['tasks'] as List).map((t) => Map<String, dynamic>.from(t)).toList();
      }
    }
  }

  TimeOfDay _parseTimeOfDay(dynamic t) {
    if (t is String && t.contains(':')) {
      final parts = t.split(':');
      return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    }
    return TimeOfDay.now();
  }

  @override
  void dispose() {
    super.dispose();
  }

  int _calculateDuration() {
    final start = DateTime(2024, 1, 1, _startTime.hour, _startTime.minute);
    final end = DateTime(2024, 1, 1, _endTime.hour, _endTime.minute);
    final duration = end.difference(start);
    return duration.inMinutes > 0 ? duration.inMinutes : duration.inMinutes + 1440;
  }

  String _getChildDeviceName(String childDeviceId) {
    try {
      final pairedDevice =
      widget.pairedDevices.firstWhere((device) => device['childDeviceId'] == childDeviceId);
      final childDeviceInfo = pairedDevice['childDeviceInfo'] as Map<String, dynamic>? ?? {};
      final deviceBrand = childDeviceInfo['brand'] ?? 'Unknown';
      final deviceModel = childDeviceInfo['device'] ?? 'Device';
      return '$deviceBrand $deviceModel';
    } catch (e) {
      return 'Unknown Device';
    }
  }

  // Fetch installed games for the selected child device (must be async)
  Future<List<Map<String, String>>> fetchInstalledGamesForChild(String childDeviceId) async {
    try {
      // Query the paired_devices to get the connectionId for this childDeviceId
      // (Assume you have it in widget.pairedDevices list)
      final pairedDevice = widget.pairedDevices.firstWhere(
            (device) => device['childDeviceId'] == childDeviceId,
        orElse: () => <String, dynamic>{},
      );
      if (pairedDevice == null) return [];

      final connectionId = pairedDevice['id'] as String?;
      if (connectionId == null || connectionId.isEmpty) return [];

      // Now get installed_games for that connectionId
      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('installed_games')
          .doc(connectionId)
          .get();

      if (!doc.exists) return [];

      final data = doc.data() as Map<String, dynamic>?;
      if (data == null || !data.containsKey('games')) return [];

      List<Map<String, String>> gamesList = [];
      for (var gameData in data['games']) {
        if (gameData is Map<String, dynamic>) {
          final name = gameData['name'] as String?;
          final packageName = gameData['packageName'] as String?;
          if (name != null && packageName != null) {
            gamesList.add({'name': name, 'packageName': packageName});
          }
        }
      }
      return gamesList;
    } catch (e) {
      print('Error fetching installed games for child: $e');
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2D3748),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 700),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Add Gaming Schedule',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Child Device Selection
                      const Text(
                        'Select Child Device',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4A5568),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedChildDeviceId,
                            hint: const Text('Choose a device', style: TextStyle(color: Colors.grey)),
                            dropdownColor: const Color(0xFF4A5568),
                            style: const TextStyle(color: Colors.white),
                            isExpanded: true,
                            items: widget.pairedDevices.map((device) {
                              final childDeviceId = device['childDeviceId'];
                              return DropdownMenuItem<String>(
                                value: childDeviceId,
                                child: Text(_getChildDeviceName(childDeviceId)),
                              );
                            }).toList(),
                            onChanged: (value) async {
                              setState(() {
                                _selectedChildDeviceId = value;
                                _isLoadingGames = true;
                                _installedGames = [];
                                _selectedGameName = null;
                              });
                              // Fetch games for selected child device
                              List<Map<String, String>> games = await fetchInstalledGamesForChild(value!);
                              setState(() {
                                _installedGames = games;
                                _isLoadingGames = false;
                              });
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Game Name
                      const Text(
                        'Game/App Name',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 8),
                      _isLoadingGames
                          ? const Center(child: CircularProgressIndicator(color: Color(0xFFE07A39)))
                          : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4A5568),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButtonFormField<String>(
                            value: _selectedGameName,
                            hint: const Text('Select a game', style: TextStyle(color: Colors.grey)),
                            dropdownColor: const Color(0xFF4A5568),
                            style: const TextStyle(color: Colors.white),
                            isExpanded: true,
                            items: _installedGames.map((game) {
                              return DropdownMenuItem<String>(
                                value: game['name'],
                                child: Text(game['name'] ?? '', overflow: TextOverflow.ellipsis),
                              );
                            }).toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedGameName = value;
                                _selectedGamePackageName = _installedGames.firstWhere((g) => g['name'] == value)['packageName'];
                              });
                            },
                            validator: (value) => value == null ? 'Please select a game' : null,
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              filled: true,
                              fillColor: Color(0xFF4A5568),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Date Selection
                      const Text('Schedule Date', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                            builder: (context, child) {
                              return Theme(
                                data: Theme.of(context).copyWith(
                                  colorScheme: const ColorScheme.dark(
                                    primary: Color(0xFFE07A39),
                                    surface: Color(0xFF2D3748),
                                  ),
                                ),
                                child: child!,
                              );
                            },
                          );
                          if (date != null) setState(() => _selectedDate = date);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4A5568),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}', style: const TextStyle(color: Colors.white)),
                              const Icon(Icons.calendar_today, color: Color(0xFFE07A39)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Time Selection
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Start Time', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () async {
                                    final time = await showTimePicker(
                                      context: context,
                                      initialTime: _startTime,
                                      builder: (context, child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme: const ColorScheme.dark(
                                              primary: Color(0xFFE07A39),
                                              surface: Color(0xFF2D3748),
                                            ),
                                          ),
                                          child: child!,
                                        );
                                      },
                                    );
                                    if (time != null) setState(() => _startTime = time);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF4A5568),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(_startTime.format(context), style: const TextStyle(color: Colors.white)),
                                        const Icon(Icons.access_time, color: Color(0xFFE07A39)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('End Time', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () async {
                                    final time = await showTimePicker(
                                      context: context,
                                      initialTime: _endTime,
                                      builder: (context, child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme: const ColorScheme.dark(
                                              primary: Color(0xFFE07A39),
                                              surface: Color(0xFF2D3748),
                                            ),
                                          ),
                                          child: child!,
                                        );
                                      },
                                    );
                                    if (time != null) setState(() => _endTime = time);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF4A5568),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(_endTime.format(context), style: const TextStyle(color: Colors.white)),
                                        const Icon(Icons.access_time, color: Color(0xFFE07A39)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Duration Display
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE07A39).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFE07A39).withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.timer, color: Color(0xFFE07A39), size: 20),
                            const SizedBox(width: 8),
                            Text('Duration: ${_calculateDuration()} minutes', style: const TextStyle(color: Color(0xFFE07A39), fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // TASKS LIST (Max 3)
                      const Text('Chores/Tasks (Max 3)', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 8),
                      Column(
                        children: List.generate(_tasks.length, (taskIdx) {
                          final task = _tasks[taskIdx];
                          return Card(
                            color: const Color(0xFF4A5568),
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  // If not enough width, stack vertically
                                  bool useColumn = constraints.maxWidth < 320;
                                  Widget mainContent = useColumn
                                      ? Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _taskDropdownOrField(task, taskIdx),
                                      const SizedBox(height: 8),
                                      _pointsDropdown(task, taskIdx),
                                      if (_tasks.length > 1) ...[
                                        const SizedBox(height: 8),
                                        _removeButton(taskIdx),
                                      ],
                                    ],
                                  )
                                      : Row(
                                    children: [
                                      Expanded(flex: 5, child: _taskDropdownOrField(task, taskIdx)),
                                      const SizedBox(width: 8),
                                      SizedBox(width: 72, child: _pointsDropdown(task, taskIdx)),
                                      if (_tasks.length > 1) ...[
                                        const SizedBox(width: 8),
                                        SizedBox(width: 32, child: _removeButton(taskIdx)),
                                      ],
                                    ],
                                  );
                                  return mainContent;
                                },
                              ),
                            ),
                          );
                        }),
                      ),
                      // Add another task button, max 3
                      if (_tasks.length < 3)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text('Add Another Task'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE07A39),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                            ),
                            onPressed: () {
                              setState(() {
                                _tasks.add({'name': null, 'custom': '', 'points': null});
                              });
                            },
                          ),
                        ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),

              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () {
                      if (_selectedChildDeviceId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Please select a child device'), backgroundColor: Colors.red),
                        );
                        return;
                      }
                      if (_selectedGameName == null || _selectedGameName!.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Please select a game'), backgroundColor: Colors.red),
                        );
                        return;
                      }
                      if (_calculateDuration() <= 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('End time must be after start time'), backgroundColor: Colors.red),
                        );
                        return;
                      }
                      // Validate tasks

                      List<Map<String, dynamic>> firestoreTasks = [];
                      for (var task in _tasks) {
                        final isCustom = task['name'] == '__custom__';
                        final nameOk = isCustom
                            ? (task['custom'] != null && task['custom'].toString().trim().isNotEmpty)
                            : (task['name'] != null);
                        if (nameOk && task['points'] != null) {
                          firestoreTasks.add({
                            'name': isCustom ? task['custom'] : task['name'],
                            'points': task['points'],
                          });
                        }
                      }

                      widget.onScheduleAdded({
                        'childDeviceId': _selectedChildDeviceId,
                        'gameName': _selectedGameName,
                        'packageName': _selectedGamePackageName,
                        'scheduledDate': _selectedDate,
                        'startTime': _startTime,
                        'endTime': _endTime,
                        'durationMinutes': _calculateDuration(),
                        'tasks': firestoreTasks.isEmpty ? null : firestoreTasks,
                        'isRecurring': _isRecurring,
                        'recurringDays': _selectedDays,
                      });
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE07A39),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Add Schedule'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _taskDropdownOrField(Map<String, dynamic> task, int taskIdx) {
    return task['name'] == '__custom__'
        ? TextFormField(
      initialValue: task['custom'],
      onChanged: (val) => setState(() => _tasks[taskIdx]['custom'] = val),
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: 'Enter custom task',
        hintStyle: TextStyle(color: Colors.grey[400]),
        filled: true,
        fillColor: const Color(0xFF4A5568),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
    )
        : DropdownButtonFormField<String>(
      value: task['name'],
      items: [
        ..._predefinedTasks.map((t) => DropdownMenuItem(
          value: t,
          child: Text(t, overflow: TextOverflow.ellipsis),
        )),
        const DropdownMenuItem(
          value: '__custom__',
          child: Text('Custom Task'),
        ),
      ],
      onChanged: (value) {
        setState(() {
          _tasks[taskIdx]['name'] = value;
          if (value != '__custom__') {
            _tasks[taskIdx]['custom'] = '';
          }
        });
      },
      decoration: const InputDecoration(
        border: InputBorder.none,
        filled: true,
        fillColor: Color(0xFF4A5568),
      ),
      hint: Text('Select task', style: TextStyle(color: Colors.grey[400])),
      validator: (value) =>
      (value == null && (_tasks[taskIdx]['custom'] == null || _tasks[taskIdx]['custom'].isEmpty))
          ? 'Please select/enter a task'
          : null,
    );
  }

  Widget _pointsDropdown(Map<String, dynamic> task, int taskIdx) {
    return DropdownButtonFormField<int>(
      value: task['points'],
      items: _pointsOptions.map((p) =>
          DropdownMenuItem<int>(value: p, child: Text('$p pts'))
      ).toList(),
      onChanged: (v) => setState(() => _tasks[taskIdx]['points'] = v),
      decoration: const InputDecoration(
        border: InputBorder.none,
        filled: true,
        fillColor: Color(0xFF4A5568),
      ),
      hint: Text('Points', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
      validator: (value) => value == null ? 'Select points' : null,
    );
  }

  Widget _removeButton(int taskIdx) {
    return IconButton(
      icon: const Icon(Icons.remove_circle, color: Colors.red, size: 22),
      onPressed: () {
        setState(() {
          _tasks.removeAt(taskIdx);
        });
      },
      tooltip: "Remove Task",
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
    );
  }
}

class _AddTaskDialog extends StatefulWidget {
  final List<Map<String, dynamic>> pairedDevices;
  final Function(String connectionId, String childDeviceId, List<Map<String, dynamic>> tasks) onTaskAdded;

  const _AddTaskDialog({
    Key? key,
    required this.pairedDevices,
    required this.onTaskAdded,
  }) : super(key: key);

  @override
  State<_AddTaskDialog> createState() => _AddTaskDialogState();
}

class _AddTaskDialogState extends State<_AddTaskDialog> {
  String? _selectedChildDeviceId;
  String? _selectedConnectionId;

  // Predefined tasks (same as schedule)
  final List<String> _predefinedTasks = [
    'Wash dishes',
    'Clean room',
    'Take out trash',
    'Feed pets',
    'Do homework',
    // ...add more as needed
  ];
  final List<int> _pointsOptions = [5, 10, 15, 20];

  List<Map<String, dynamic>> _tasks = [
    {'name': null, 'custom': '', 'points': null}
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2D3748),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 550),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Add Tasks / Chores', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedChildDeviceId,
              hint: Text('Select Child Device', style: TextStyle(color: Colors.grey[400])),
              dropdownColor: const Color(0xFF4A5568),
              style: const TextStyle(color: Colors.white),
              items: widget.pairedDevices.map((device) {
                final name = (device['childDeviceInfo']?['brand'] ?? '') + ' ' + (device['childDeviceInfo']?['device'] ?? '');
                return DropdownMenuItem<String>(
                  value: device['childDeviceId'],
                  child: Text(name),
                );
              }).toList(),
              onChanged: (val) {
                setState(() {
                  _selectedChildDeviceId = val;
                  _selectedConnectionId = widget.pairedDevices.firstWhere((d) => d['childDeviceId'] == val)['id'];
                });
              },
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF4A5568),
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Column(
                      children: List.generate(_tasks.length, (taskIdx) {
                        final task = _tasks[taskIdx];
                        return Card(
                          color: const Color(0xFF4A5568),
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                // Use Column if not enough width, Row otherwise
                                bool useColumn = constraints.maxWidth < 320;
                                if (useColumn) {
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _taskDropdownOrField(task, taskIdx),
                                      const SizedBox(height: 8),
                                      _pointsDropdown(task, taskIdx),
                                      if (_tasks.length > 1) ...[
                                        const SizedBox(height: 8),
                                        _removeButton(taskIdx),
                                      ],
                                    ],
                                  );
                                } else {
                                  return Row(
                                    children: [
                                      Flexible(flex: 5, child: _taskDropdownOrField(task, taskIdx)),
                                      const SizedBox(width: 8),
                                      Flexible(flex: 2, child: _pointsDropdown(task, taskIdx)),
                                      if (_tasks.length > 1) ...[
                                        const SizedBox(width: 8),
                                        SizedBox(width: 32, child: _removeButton(taskIdx)),
                                      ],
                                    ],
                                  );
                                }
                              },
                            ),
                          ),
                        );
                      }),
                    ),
                    if (_tasks.length < 3)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Add Another Task'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE07A39),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                          ),
                          onPressed: () {
                            setState(() {
                              _tasks.add({'name': null, 'custom': '', 'points': null});
                            });
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                if (_selectedChildDeviceId == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please select a child device'), backgroundColor: Colors.red),
                  );
                  return;
                }

                // Only submit non-empty tasks
                List<Map<String, dynamic>> validTasks = [];
                for (var task in _tasks) {
                  final isCustom = task['name'] == '__custom__';
                  final nameOk = isCustom
                      ? (task['custom'] != null && task['custom'].toString().trim().isNotEmpty)
                      : (task['name'] != null);
                  if (nameOk && task['points'] != null) {
                    validTasks.add({
                      'name': isCustom ? task['custom'] : task['name'],
                      'points': task['points'],
                    });
                  }
                }
                if (validTasks.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please fill at least one task and points.'), backgroundColor: Colors.red),
                  );
                  return;
                }
                widget.onTaskAdded(_selectedConnectionId!, _selectedChildDeviceId!, validTasks);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE07A39),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Add Task(s)'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskDropdownOrField(Map<String, dynamic> task, int taskIdx) {
    return task['name'] == '__custom__'
        ? TextFormField(
      initialValue: task['custom'],
      onChanged: (val) => setState(() => _tasks[taskIdx]['custom'] = val),
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: 'Enter custom task',
        hintStyle: TextStyle(color: Colors.grey[400]),
        filled: true,
        fillColor: const Color(0xFF4A5568),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
    )
        : DropdownButtonFormField<String>(
      value: task['name'],
      items: [
        ..._predefinedTasks.map((t) => DropdownMenuItem(
          value: t,
          child: Text(t, overflow: TextOverflow.ellipsis),
        )),
        const DropdownMenuItem(
          value: '__custom__',
          child: Text('Custom Task'),
        ),
      ],
      onChanged: (value) {
        setState(() {
          _tasks[taskIdx]['name'] = value;
          if (value != '__custom__') {
            _tasks[taskIdx]['custom'] = '';
          }
        });
      },
      decoration: const InputDecoration(
        border: InputBorder.none,
        filled: true,
        fillColor: Color(0xFF4A5568),
      ),
      hint: Text('Select task', style: TextStyle(color: Colors.grey[400])),
      validator: (value) =>
      (value == null && (_tasks[taskIdx]['custom'] == null || _tasks[taskIdx]['custom'].isEmpty))
          ? 'Please select/enter a task'
          : null,
    );
  }

  Widget _pointsDropdown(Map<String, dynamic> task, int taskIdx) {
    return DropdownButtonFormField<int>(
      value: task['points'],
      items: _pointsOptions.map((p) =>
          DropdownMenuItem<int>(value: p, child: Text('$p pts'))
      ).toList(),
      onChanged: (v) => setState(() => _tasks[taskIdx]['points'] = v),
      decoration: const InputDecoration(
        border: InputBorder.none,
        filled: true,
        fillColor: Color(0xFF4A5568),
      ),
      hint: Text('Points', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
      validator: (value) => value == null ? 'Select points' : null,
    );
  }

  Widget _removeButton(int taskIdx) {
    return IconButton(
      icon: const Icon(Icons.remove_circle, color: Colors.red, size: 22),
      onPressed: () {
        setState(() {
          _tasks.removeAt(taskIdx);
        });
      },
      tooltip: "Remove Task",
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
    );
  }
}

