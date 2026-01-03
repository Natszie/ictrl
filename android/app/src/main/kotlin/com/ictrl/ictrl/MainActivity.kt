package com.ictrl.ictrl

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.app.usage.UsageStatsManager
import android.app.usage.UsageStats
import android.os.Build
import android.net.Uri
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.firebase.FirebaseApp

class MainActivity: FlutterActivity() {
    private val ENHANCED_BACKGROUND_MONITOR_CHANNEL = "com.ictrl.ictrl/enhanced_background_monitor"
    private val APP_MONITOR_CHANNEL = "com.ictrl.ictrl/app_monitor"

    // Request codes for startActivityForResult
    private val OVERLAY_PERMISSION_REQUEST_CODE = 1001
    private val DEVICE_ADMIN_REQUEST_CODE = 1002

    private var connectionId: String = "unknown_connection"
    private var childDeviceId: String = "unknown_child_device"

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Initialize Firebase here!
        FirebaseApp.initializeApp(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Enhanced Background Monitor Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENHANCED_BACKGROUND_MONITOR_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startEnhancedService" -> {
                    val monitoredGames = call.argument<List<String>>("monitoredGames") ?: emptyList()
                    val allowedGames = call.argument<List<String>>("allowedGames") ?: emptyList()
                    val connectionId = call.argument<String>("connectionId") ?: "unknown_connection"
                    val childDeviceId = call.argument<String>("childDeviceId") ?: "unknown_child_device"
                    val started = EnhancedBackgroundMonitorService.startService(
                        this, monitoredGames.toSet(), allowedGames.toSet(), connectionId, childDeviceId
                    )
                    result.success(true)
                }
                "stopEnhancedService" -> {
                    stopEnhancedMonitorService()
                    result.success(true)
                }
                "updateGamePermissions" -> {
                    val monitoredGames = call.argument<List<String>>("monitoredGames") ?: emptyList()
                    val allowedGames = call.argument<List<String>>("allowedGames") ?: emptyList()
                    EnhancedBackgroundMonitorService.updateMonitoredGames(monitoredGames.toSet(), allowedGames.toSet())
                    result.success(true)
                }
                "emergencyStop" -> {
                    emergencyStopAllBlocking()
                    result.success(true)
                }
                "bringToForeground" -> {
                    bringAppToForeground()
                    result.success(true)
                }
                "forceImmediateCheck" -> {
                    EnhancedBackgroundMonitorService.forceImmediateCheck()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Enhanced App Monitor Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_MONITOR_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasUsageStatsPermission" -> {
                    result.success(hasUsageStatsPermission())
                }
                "requestUsageStatsPermission" -> {
                    requestUsageStatsPermission()
                    result.success(true)
                }
                "hasOverlayPermission" -> {
                    result.success(hasOverlayPermission())
                }
                "requestOverlayPermission" -> {
                    requestOverlayPermission()
                    result.success(true)
                }
                "isDeviceAdmin" -> {
                    result.success(isDeviceAdmin())
                }
                "requestDeviceAdmin" -> {
                    requestDeviceAdminPermission()
                    result.success(true)
                }
                "getRunningApps" -> {
                    val runningApps = getRecentlyUsedApps()
                    result.success(runningApps)
                }
                "closeApp" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        closeApp(packageName)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "Package name is required", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Set up enhanced game detection callback
        EnhancedBackgroundMonitorService.onGameDetected = { packageName, isBlocked ->
            try {
                println("🎮 🛡️ [MAIN] Native detected game: $packageName, blocked: $isBlocked")

                val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENHANCED_BACKGROUND_MONITOR_CHANNEL)

                // Ensure we're on the main thread
                runOnUiThread {
                    try {
                        channel.invokeMethod("gameDetected", mapOf(
                            "packageName" to packageName,
                            "isBlocked" to isBlocked
                        ))
                        println("🎮 🛡️ [MAIN] ✅ Successfully sent to Flutter: $packageName")
                    } catch (e: Exception) {
                        println("🎮 ❌ [MAIN] Error invoking Flutter method: ${e.message}")
                        e.printStackTrace()
                    }
                }
            } catch (e: Exception) {
                println("🎮 ❌ [MAIN] Error in game detection callback: ${e.message}")
                e.printStackTrace()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        when (requestCode) {
            OVERLAY_PERMISSION_REQUEST_CODE -> {
                if (hasOverlayPermission()) {
                    println("🎮 🛡️ [MAIN] Overlay permission granted")
                } else {
                    println("🎮 ❌ [MAIN] Overlay permission denied")
                }
            }
            DEVICE_ADMIN_REQUEST_CODE -> {
                if (isDeviceAdmin()) {
                    println("🎮 🛡️ [MAIN] Device admin permission granted")
                } else {
                    println("🎮 ❌ [MAIN] Device admin permission denied")
                }
            }
        }
    }

    private fun startEnhancedMonitorService(monitoredGames: Set<String>, allowedGames: Set<String>): Boolean {
        return try {
            println("🎮 🛡️ [MAIN] Starting enhanced service - Monitored: ${monitoredGames.size}, Allowed: ${allowedGames.size}")
            EnhancedBackgroundMonitorService.startService(this, monitoredGames, allowedGames)
            true
        } catch (e: Exception) {
            println("🎮 ❌ [MAIN] Error starting enhanced service: ${e.message}")
            e.printStackTrace()
            false
        }
    }

    private fun stopEnhancedMonitorService() {
        println("🎮 🛡️ [MAIN] Stopping enhanced service")
        EnhancedBackgroundMonitorService.stopService(this)
    }

    private fun emergencyStopAllBlocking() {
        println("🎮 🛡️ [MAIN] 🚨 EMERGENCY STOP - Stopping all blocking")
        stopEnhancedMonitorService()

        // Clear all notifications
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        notificationManager.cancelAll()
    }

    private fun bringAppToForeground() {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        startActivity(intent)
    }

    private fun hasUsageStatsPermission(): Boolean {
        val appOpsManager = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOpsManager.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            )
        } else {
            appOpsManager.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun requestUsageStatsPermission() {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
        startActivity(intent)
    }

    private fun hasOverlayPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else {
            true // Permission not required for older versions
        }
    }

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            )
            @Suppress("DEPRECATION")
            startActivityForResult(intent, OVERLAY_PERMISSION_REQUEST_CODE)
        }
    }

    private fun isDeviceAdmin(): Boolean {
        val devicePolicyManager = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val componentName = ComponentName(this, ICTRLDeviceAdminReceiver::class.java)
        return devicePolicyManager.isAdminActive(componentName)
    }

    private fun requestDeviceAdminPermission() {
        val devicePolicyManager = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val componentName = ComponentName(this, ICTRLDeviceAdminReceiver::class.java)

        if (!devicePolicyManager.isAdminActive(componentName)) {
            val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, componentName)
                putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                    "iCTRL needs device admin access to better protect against unauthorized game access. This helps ensure parental controls cannot be easily bypassed.")
            }
            @Suppress("DEPRECATION")
            startActivityForResult(intent, DEVICE_ADMIN_REQUEST_CODE)
        }
    }

    private fun getRecentlyUsedApps(): List<String> {
        if (!hasUsageStatsPermission()) {
            println("🎮 🛡️ [MAIN] No usage stats permission")
            return emptyList()
        }

        try {
            val usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val endTime = System.currentTimeMillis()
            val beginTime = endTime - (10 * 1000) // Last 10 seconds

            val stats = usageStatsManager.queryUsageStats(
                UsageStatsManager.INTERVAL_BEST,
                beginTime,
                endTime
            )

            val recentApps = mutableListOf<String>()

            // Find apps that were used in the last 10 seconds
            stats?.forEach { stat ->
                if (stat.lastTimeUsed > beginTime &&
                    stat.packageName != packageName &&
                    stat.totalTimeInForeground > 0) {
                    recentApps.add(stat.packageName)
                }
            }

            println("🎮 🛡️ [MAIN] Found ${recentApps.size} recently active apps: $recentApps")
            return recentApps

        } catch (e: Exception) {
            println("🎮 ❌ [MAIN] Error getting recent apps: ${e.message}")
            e.printStackTrace()
            return emptyList()
        }
    }

    private fun closeApp(packageName: String) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                // For newer versions, bring home screen to foreground
                val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                    addCategory(Intent.CATEGORY_HOME)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(homeIntent)

                // Also bring iCTRL to foreground
                bringAppToForeground()

                println("🎮 🛡️ [MAIN] Attempted to close $packageName by launching home and iCTRL")
            }
        } catch (e: Exception) {
            println("🎮 ❌ [MAIN] Error closing app $packageName: ${e.message}")
            e.printStackTrace()
        }
    }


}