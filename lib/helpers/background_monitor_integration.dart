import 'package:flutter/services.dart';

class BackgroundMonitorIntegration {
  static const MethodChannel _backgroundChannel =
  MethodChannel('com.ictrl.ictrl/background_monitor');

  static bool _isMonitoring = false;
  static Function(String)? _onGameDetected;

  // Start background monitoring for the provided games.
  static Future<bool> startMonitoring(List<String> gamePackages, Function(String) onGameDetected) async {
    try {
      if (_isMonitoring) return true;
      _onGameDetected = onGameDetected;

      _backgroundChannel.setMethodCallHandler((call) async {
        if (call.method == "gameDetected") {
          String packageName = call.arguments as String;
          if (_onGameDetected != null) _onGameDetected!(packageName);
        }
      });

      final bool success = await _backgroundChannel.invokeMethod('startForegroundService', {
        'games': gamePackages,
      });
      if (success) _isMonitoring = true;
      return success;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopMonitoring() async {
    if (!_isMonitoring) return;
    await _backgroundChannel.invokeMethod('stopForegroundService');
    _isMonitoring = false;
    _onGameDetected = null;
  }

  static Future<bool> hasUsageStatsPermission() async {
    try {
      return await _backgroundChannel.invokeMethod('checkPermissions');
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestUsageStatsPermission() async {
    await _backgroundChannel.invokeMethod('requestPermissions');
  }
}