import 'package:shared_preferences/shared_preferences.dart';

class MonitoringPreferences {
  static const String _autoStartKey = 'enhanced_monitoring_auto_start';
  static const String _connectionIdKey = 'enhanced_monitoring_connection_id';
  static const String _monitoredGamesKey = 'enhanced_monitoring_games';
  static const String _lastUpdateKey = 'enhanced_monitoring_last_update';

  // Save monitoring state
  static Future<void> saveMonitoringState({
    required bool autoStart,
    required String connectionId,
    required List<String> monitoredGames,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setBool(_autoStartKey, autoStart);
      await prefs.setString(_connectionIdKey, connectionId);
      await prefs.setStringList(_monitoredGamesKey, monitoredGames);
      await prefs.setInt(_lastUpdateKey, DateTime.now().millisecondsSinceEpoch);

      print('🎮 🛡️ Saved monitoring preferences - ConnectionId: $connectionId, Games: ${monitoredGames.length}');
    } catch (e) {
      print('🎮 ❌ Error saving monitoring preferences: $e');
    }
  }

  // Load monitoring state
  static Future<Map<String, dynamic>> loadMonitoringState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      bool autoStart = prefs.getBool(_autoStartKey) ?? false;
      String? connectionId = prefs.getString(_connectionIdKey);
      List<String> monitoredGames = prefs.getStringList(_monitoredGamesKey) ?? [];
      int? lastUpdate = prefs.getInt(_lastUpdateKey);

      print('🎮 🛡️ Loaded monitoring preferences - ConnectionId: $connectionId, Games: ${monitoredGames.length}');

      return {
        'autoStart': autoStart,
        'connectionId': connectionId,
        'monitoredGames': monitoredGames,
        'lastUpdate': lastUpdate != null ? DateTime.fromMillisecondsSinceEpoch(lastUpdate) : null,
      };
    } catch (e) {
      print('🎮 ❌ Error loading monitoring preferences: $e');
      return {
        'autoStart': false,
        'connectionId': null,
        'monitoredGames': <String>[],
        'lastUpdate': null,
      };
    }
  }

  // Save connectionId separately (for quick access)
  static Future<void> saveConnectionId(String connectionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_connectionIdKey, connectionId);
      print('🎮 🛡️ Saved connectionId: $connectionId');
    } catch (e) {
      print('🎮 ❌ Error saving connectionId: $e');
    }
  }

  // Get connectionId
  static Future<String?> getConnectionId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? connectionId = prefs.getString(_connectionIdKey);
      print('🎮 🛡️ Retrieved connectionId: $connectionId');
      return connectionId;
    } catch (e) {
      print('🎮 ❌ Error getting connectionId: $e');
      return null;
    }
  }

  // Check if auto-start is enabled
  static Future<bool> shouldAutoStart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      bool autoStart = prefs.getBool(_autoStartKey) ?? false;
      String? connectionId = prefs.getString(_connectionIdKey);

      // Only auto-start if we have both the flag and a valid connectionId
      bool shouldStart = autoStart && connectionId != null && connectionId.isNotEmpty;

      print('🎮 🛡️ Should auto-start: $shouldStart (autoStart: $autoStart, hasConnectionId: ${connectionId != null})');
      return shouldStart;
    } catch (e) {
      print('🎮 ❌ Error checking auto-start: $e');
      return false;
    }
  }

  // Clear all monitoring preferences
  static Future<void> clearMonitoringState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.remove(_autoStartKey);
      await prefs.remove(_connectionIdKey);
      await prefs.remove(_monitoredGamesKey);
      await prefs.remove(_lastUpdateKey);

      print('🎮 🛡️ Cleared monitoring preferences');
    } catch (e) {
      print('🎮 ❌ Error clearing monitoring preferences: $e');
    }
  }

  // Update monitored games list
  static Future<void> updateMonitoredGames(List<String> games) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_monitoredGamesKey, games);
      await prefs.setInt(_lastUpdateKey, DateTime.now().millisecondsSinceEpoch);

      print('🎮 🛡️ Updated monitored games: ${games.length} games');
    } catch (e) {
      print('🎮 ❌ Error updating monitored games: $e');
    }
  }

  // Get monitored games
  static Future<List<String>> getMonitoredGames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> games = prefs.getStringList(_monitoredGamesKey) ?? [];
      return games;
    } catch (e) {
      print('🎮 ❌ Error getting monitored games: $e');
      return [];
    }
  }

  // Check if preferences are expired (older than 24 hours)
  static Future<bool> arePreferencesExpired() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      int? lastUpdate = prefs.getInt(_lastUpdateKey);

      if (lastUpdate == null) return true;

      DateTime lastUpdateTime = DateTime.fromMillisecondsSinceEpoch(lastUpdate);
      Duration difference = DateTime.now().difference(lastUpdateTime);

      bool expired = difference.inHours > 24;
      print('🎮 🛡️ Preferences expired: $expired (age: ${difference.inHours} hours)');

      return expired;
    } catch (e) {
      print('🎮 ❌ Error checking preferences expiry: $e');
      return true; // Assume expired on error
    }
  }

  // Debug method to print all stored preferences
  static Future<void> debugPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      print('🔍 === MONITORING PREFERENCES DEBUG ===');
      print('🔍 Auto Start: ${prefs.getBool(_autoStartKey)}');
      print('🔍 Connection ID: ${prefs.getString(_connectionIdKey)}');
      print('🔍 Monitored Games: ${prefs.getStringList(_monitoredGamesKey)}');
      print('🔍 Last Update: ${prefs.getInt(_lastUpdateKey)}');
      print('🔍 === END DEBUG ===');
    } catch (e) {
      print('🎮 ❌ Error debugging preferences: $e');
    }
  }
}