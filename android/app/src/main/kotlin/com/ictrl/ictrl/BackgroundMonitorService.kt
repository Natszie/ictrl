package com.ictrl.ictrl

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.app.usage.UsageStats
import android.app.usage.UsageStatsManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import android.view.WindowManager
import android.graphics.PixelFormat
import android.view.View
import android.widget.ImageView
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import android.graphics.Color
import android.view.ViewGroup
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.google.firebase.Timestamp
import kotlinx.coroutines.*

class EnhancedBackgroundMonitorService : Service() {
    private val CHANNEL_ID = "ENHANCED_GAME_MONITOR_CHANNEL"
    private val NOTIFICATION_ID = 1001
    private val BLOCK_NOTIFICATION_ID = 2001
    private val handler = Handler(Looper.getMainLooper())
    private var monitoringRunnable: Runnable? = null
    private var isMonitoring = false
    private var lastCheckedTime = 0L
    private var currentlyBlockedPackage: String? = null
    private var blockingOverlay: View? = null
    private var windowManager: WindowManager? = null
    private var isBlocking = false

    // Game blocking state
    private var blockedGames = mutableSetOf<String>()
    private var consecutiveDetections = mutableMapOf<String, Int>()
    private var notRunningDetections = mutableMapOf<String, Int>()

    private var connectionId: String = "unknown_connection"
    private var childDeviceId: String = "unknown_child_device"
    private val allowedRunning = mutableSetOf<String>()

    companion object {
        var monitoredGames = mutableSetOf<String>()
        var allowedGames = mutableSetOf<String>() // Games that are currently allowed
        var onGameDetected: ((String, Boolean) -> Unit)? = null // packageName, isBlocked
        private var serviceInstance: EnhancedBackgroundMonitorService? = null

        fun startService(
            context: Context,
            games: Set<String>,
            allowed: Set<String> = emptySet(),
            connectionId: String = "unknown_connection",
            childDeviceId: String = "unknown_child_device"
        ) {
            println("🎮 [ENHANCED] Starting enhanced service with ${games.size} games to monitor")
            monitoredGames = games.toMutableSet()
            allowedGames = allowed.toMutableSet()
            val intent = Intent(context, EnhancedBackgroundMonitorService::class.java)
            intent.putExtra("connectionId", connectionId)
            intent.putExtra("childDeviceId", childDeviceId)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun forceImmediateCheck() {
            serviceInstance?.performEnhancedCheck()
        }

        fun stopService(context: Context) {
            println("🎮 [ENHANCED] Stopping enhanced service")
            val intent = Intent(context, EnhancedBackgroundMonitorService::class.java)
            context.stopService(intent)
        }

        fun updateMonitoredGames(games: Set<String>, allowed: Set<String> = emptySet()) {
            println("🎮 [ENHANCED] Updating - Monitored: $games, Allowed: $allowed")
            monitoredGames = games.toMutableSet()
            allowedGames = allowed.toMutableSet()
        }

        fun updateAllowedGames(allowed: Set<String>) {
            println("🎮 [ENHANCED] Updating allowed games: $allowed")
            allowedGames = allowed.toMutableSet()
        }
    }

    override fun onCreate() {
        super.onCreate()
        println("🎮 [ENHANCED] onCreate called")
        createNotificationChannel()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        lastCheckedTime = System.currentTimeMillis()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        connectionId = intent?.getStringExtra("connectionId") ?: "unknown_connection"
        childDeviceId = intent?.getStringExtra("childDeviceId") ?: "unknown_child_device"
        println("🎮 [ENHANCED] onStartCommand called")
        startForeground(NOTIFICATION_ID, createNotification())
        startEnhancedMonitoring()
        return START_STICKY // Always restart if killed
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Main monitoring channel
            val monitorChannel = NotificationChannel(
                CHANNEL_ID,
                "ICTRL System Service Running",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Game Monitoring Active"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }

            // Blocking alert channel
            val blockChannel = NotificationChannel(
                "GAME_BLOCK_CHANNEL",
                "Game Blocking Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alerts when games are blocked"
                enableVibration(true)
                setSound(Settings.System.DEFAULT_NOTIFICATION_URI, null)
            }

            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(monitorChannel)
            manager.createNotificationChannel(blockChannel)
            println("🎮 [ENHANCED] Notification channels created")
        }
    }

    private fun createNotification(): Notification {
        val blockedCount = blockedGames.size
        val statusText = if (blockedCount > 0) {
            "Blocking $blockedCount game(s)"
        } else {
            "Monitoring ${monitoredGames.size} games"
        }

        // Create intent to reopen main app
        val reopenIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val reopenPendingIntent = PendingIntent.getActivity(
            this, 0, reopenIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("System running in background")
            .setContentText(statusText)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(reopenPendingIntent)
            .build()
    }

    fun logViolationToFirestore(
        connectionId: String,
        childDeviceId: String,
        gameName: String,
        packageName: String
    ) {
        val db = FirebaseFirestore.getInstance()

        val violationData = hashMapOf(
            "connectionId" to connectionId,
            "childDeviceId" to childDeviceId,
            "childName" to "Child Device",
            "gameName" to gameName,
            "packageName" to packageName,
            "violationType" to "enhanced_unauthorized_launch",
            "timestamp" to Timestamp.now(),
            "detectedAt" to Timestamp.now(),
            "description" to "Game launched outside app - enhanced blocking active",
            "blockingMethod" to "enhanced_overlay_and_aggressive",
            "severity" to "high",
            "screenLock" to false,
            "blockedSuccessfully" to true,
            "deviceType" to "android",
            "monitoringLevel" to "enhanced",
            "actionTaken" to "game_blocked_immediately"
        )

        db.collection("violations")
            .document(connectionId)
            .set(violationData, SetOptions.merge())
            .addOnSuccessListener {
                println("🎮 [ENHANCED] ✅ Successfully logged violation for: $gameName (docId: $connectionId)")
            }
            .addOnFailureListener { e ->
                println("🎮 [ENHANCED] ❌ Failed to log violation: ${e.message}")
            }
    }

    private fun createEmergencyStopIntent(): PendingIntent {
        val stopIntent = Intent(this, EmergencyStopReceiver::class.java)
        return PendingIntent.getBroadcast(
            this, 0, stopIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )
    }

    private fun startEnhancedMonitoring() {
        if (isMonitoring) {
            println("🎮 [ENHANCED] Already monitoring, skipping start")
            return
        }

        println("🎮 [ENHANCED] Starting enhanced monitoring with ${monitoredGames.size} games")
        isMonitoring = true

        monitoringRunnable = object : Runnable {
            override fun run() {
                if (isMonitoring) {
                    performEnhancedCheck()
                    handler.postDelayed(this, 1500) // Check every 1.5 seconds
                }
            }
        }
        handler.post(monitoringRunnable!!)
        println("🎮 [ENHANCED] Enhanced monitoring started with 1.5-second intervals")
    }

    private fun performEnhancedCheck() {
        try {
            if (monitoredGames.isEmpty()) return

            if (!hasUsageStatsPermission()) {
                println("🎮 [ENHANCED] No usage stats permission")
                return
            }

            val runningGames = detectRunningGames()

            for (packageName in runningGames) {
                handleGameDetection(packageName)
            }

            // Clean up old detections
            cleanupOldDetections()

            // Update notification
            updateServiceNotification()

        } catch (e: Exception) {
            println("🎮 [ENHANCED] Error in enhanced check: ${e.message}")
            e.printStackTrace()
        }
    }

    private fun detectRunningGames(): List<String> {
        val detectedGames = mutableListOf<String>()

        try {
            val usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val endTime = System.currentTimeMillis()
            val beginTime = maxOf(lastCheckedTime, endTime - 5000) // Last 5 seconds

            val stats = usageStatsManager.queryUsageStats(
                UsageStatsManager.INTERVAL_BEST,
                beginTime,
                endTime
            )

            if (stats.isNullOrEmpty()) return detectedGames

            // Find recently used monitored games
            for (stat in stats) {
                if (stat.lastTimeUsed > lastCheckedTime &&
                    monitoredGames.contains(stat.packageName) &&
                    stat.packageName != packageName) {

                    detectedGames.add(stat.packageName)
                }
            }

            lastCheckedTime = endTime

        } catch (e: Exception) {
            println("🎮 [ENHANCED] Error detecting games: ${e.message}")
        }

        return detectedGames
    }

    private fun handleGameDetection(packageName: String) {
        // Increment consecutive detections
        consecutiveDetections[packageName] = (consecutiveDetections[packageName] ?: 0) + 1

        val detectionCount = consecutiveDetections[packageName] ?: 0
        val isGameAllowed = allowedGames.contains(packageName)

        println("🎮 [ENHANCED] Detected: $packageName (count: $detectionCount, allowed: $isGameAllowed)")

        if (!isGameAllowed && detectionCount >= 1) {
            // Block after 2+ consecutive detections
            initiateGameBlocking(packageName)
        } else if (isGameAllowed) {
            // Only notify once per "start" (after 2+ consecutive detections)
            if (detectionCount >= 1 && !allowedRunning.contains(packageName)) {
                allowedRunning.add(packageName)
                onGameDetected?.invoke(packageName, false)
            }

            // If previously blocked, un-block visuals
            if (blockedGames.contains(packageName)) {
                blockedGames.remove(packageName)
                stopBlocking()
            }
        }
    }

    private fun initiateGameBlocking(packageName: String) {
        if (blockedGames.contains(packageName) && isBlocking) {
            // Already blocking this game, continue blocking
            continueBlocking(packageName)
            return
        }

        println("🎮 [ENHANCED] 🚫 INITIATING BLOCK for: $packageName")

        blockedGames.add(packageName)
        currentlyBlockedPackage = packageName

        // Notify Flutter app
        onGameDetected?.invoke(packageName, true)

        // Start aggressive blocking
        startAggressiveBlocking(packageName)

        // Show blocking notification
        showBlockingNotification(packageName)

        val gameName = getAppName(packageName)
        logViolationToFirestore(connectionId, childDeviceId, gameName, packageName)
    }

    private fun startAggressiveBlocking(packageName: String) {
        isBlocking = true

        // Method 1: Show fullscreen blocking overlay
        showBlockingOverlay(packageName)

        // Method 2: Continuously attempt to close the game
        startGameClosingLoop(packageName)

        // Method 3: Launch iCTRL app repeatedly
        startICTRLLauncher()
    }

    private fun showBlockingOverlay(packageName: String) {
        if (!Settings.canDrawOverlays(this)) {
            println("🎮 [ENHANCED] No overlay permission")
            return
        }

        try {
            // Remove existing overlay
            removeBlockingOverlay()

            // Create blocking overlay
            val layoutParams = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                } else {
                    WindowManager.LayoutParams.TYPE_PHONE
                },
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_FULLSCREEN,
                PixelFormat.TRANSLUCENT
            )

            layoutParams.gravity = Gravity.CENTER

            // Create overlay view
            blockingOverlay = createBlockingOverlayView(packageName)
            windowManager?.addView(blockingOverlay, layoutParams)

            println("🎮 [ENHANCED] Blocking overlay shown for: $packageName")

        } catch (e: Exception) {
            println("🎮 [ENHANCED] Error showing overlay: ${e.message}")
            e.printStackTrace()
        }
    }

    private fun createBlockingOverlayView(packageName: String): View {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#CC000000"))
            gravity = Gravity.CENTER
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        // Add blocking icon
        val icon = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_delete)
            layoutParams = LinearLayout.LayoutParams(200, 200).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = 40
            }
        }
        layout.addView(icon)

        // Add title
        val title = TextView(this).apply {
            text = "🚫 GAME BLOCKED"
            textSize = 28f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = 20
            }
        }
        layout.addView(title)

        // Add message
        val message = TextView(this).apply {
            text = "This game is not allowed at this time.\nReturn to iCTRL to continue."
            textSize = 16f
            setTextColor(Color.parseColor("#CCFFFFFF"))
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }
        layout.addView(message)

        return layout
    }

    private fun startGameClosingLoop(packageName: String) {
        // Continuously attempt to close the blocked game
        val closeHandler = Handler(Looper.getMainLooper())
        val closeRunnable = object : Runnable {
            override fun run() {
                if (isBlocking && blockedGames.contains(packageName)) {
                    attemptToCloseGame(packageName)
                    closeHandler.postDelayed(this, 2000) // Try every 2 seconds
                }
            }
        }
        closeHandler.post(closeRunnable)
    }

    private fun startICTRLLauncher() {
        // Continuously launch iCTRL
        val launchHandler = Handler(Looper.getMainLooper())
        val launchRunnable = object : Runnable {
            override fun run() {
                if (isBlocking) {
                    launchICTRL()
                    launchHandler.postDelayed(this, 3000) // Launch every 3 seconds
                }
            }
        }
        launchHandler.post(launchRunnable)
    }

    private fun attemptToCloseGame(packageName: String) {
        try {
            // Method 1: Try to kill the app (requires root, usually fails)
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager

            // Method 2: Launch home screen
            val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(homeIntent)

            println("🎮 [ENHANCED] Attempted to close game: $packageName")

        } catch (e: Exception) {
            println("🎮 [ENHANCED] Error closing game: ${e.message}")
        }
    }

    private fun launchICTRL() {
        try {
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }

            if (launchIntent != null) {
                startActivity(launchIntent)
                println("🎮 [ENHANCED] Launched iCTRL")
            }

        } catch (e: Exception) {
            println("🎮 [ENHANCED] Error launching iCTRL: ${e.message}")
        }
    }

    private fun continueBlocking(packageName: String) {
        // Continue aggressive blocking for persistent games
        if (isBlocking && blockingOverlay == null) {
            showBlockingOverlay(packageName)
        }
    }

    private fun stopBlocking() {
        println("🎮 [ENHANCED] Stopping all blocking")
        isBlocking = false
        currentlyBlockedPackage = null
        removeBlockingOverlay()
        dismissBlockingNotification()
    }

    private fun removeBlockingOverlay() {
        try {
            blockingOverlay?.let { overlay ->
                windowManager?.removeView(overlay)
                blockingOverlay = null
                println("🎮 [ENHANCED] Blocking overlay removed")
            }
        } catch (e: Exception) {
            println("🎮 [ENHANCED] Error removing overlay: ${e.message}")
        }
    }

    private fun showBlockingNotification(packageName: String) {
        try {
            val gameName = getAppName(packageName)

            val notification = NotificationCompat.Builder(this, "GAME_BLOCK_CHANNEL")
                .setContentTitle("🚫 Game Blocked")
                .setContentText("$gameName is not allowed right now")
                .setSmallIcon(android.R.drawable.ic_delete)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(false)
                .setOngoing(true)
                .setVibrate(longArrayOf(0, 500, 200, 500))
                .build()

            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.notify(BLOCK_NOTIFICATION_ID, notification)

        } catch (e: Exception) {
            println("🎮 [ENHANCED] Error showing blocking notification: ${e.message}")
        }
    }

    private fun dismissBlockingNotification() {
        try {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(BLOCK_NOTIFICATION_ID)
        } catch (e: Exception) {
            println("🎮 [ENHANCED] Error dismissing notification: ${e.message}")
        }
    }

    private fun cleanupOldDetections() {
        val iterator = consecutiveDetections.iterator()
        val runningGames = detectRunningGames() // compute once

        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (!runningGames.contains(entry.key)) {
                val notRunningCount = (notRunningDetections[entry.key] ?: 0) + 1
                notRunningDetections[entry.key] = notRunningCount

                if (notRunningCount >= 3) {
                    iterator.remove()
                    notRunningDetections.remove(entry.key)
                    // Forget "allowed running" state so a future start will notify again
                    allowedRunning.remove(entry.key)

                    if (blockedGames.contains(entry.key)) {
                        blockedGames.remove(entry.key)
                        if (blockedGames.isEmpty()) stopBlocking()
                    }
                }
            } else {
                notRunningDetections[entry.key] = 0
            }
        }
    }

    private fun updateServiceNotification() {
        try {
            val notification = createNotification()
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            println("🎮 [ENHANCED] Error updating notification: ${e.message}")
        }
    }

    private fun getAppName(packageName: String): String {
        return try {
            val packageManager = packageManager
            val appInfo = packageManager.getApplicationInfo(packageName, 0)
            packageManager.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            packageName
        }
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

    override fun onDestroy() {
        println("🎮 [ENHANCED] Service destroyed")
        isMonitoring = false
        stopBlocking()
        monitoringRunnable?.let { handler.removeCallbacks(it) }
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val restartIntent = Intent(applicationContext, EnhancedBackgroundMonitorService::class.java)
        startService(restartIntent)
        super.onTaskRemoved(rootIntent)
    }

    fun forceImmediateCheck() {
        performEnhancedCheck()
    }


}