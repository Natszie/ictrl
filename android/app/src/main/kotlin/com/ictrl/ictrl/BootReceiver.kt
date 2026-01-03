package com.ictrl.ictrl

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        println("🎮 [BOOT] Boot receiver triggered: ${intent.action}")

        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                println("🎮 [BOOT] Device booted, checking if monitoring should start")

                // Check if we have stored monitoring preferences
                val prefs = context.getSharedPreferences("ictrl_monitoring", Context.MODE_PRIVATE)
                val shouldAutoStart = prefs.getBoolean("auto_start_monitoring", false)
                val connectionId = prefs.getString("connection_id", null)

                if (shouldAutoStart && !connectionId.isNullOrEmpty()) {
                    println("🎮 [BOOT] Auto-starting monitoring service for connection: $connectionId")

                    // Start the background monitoring service
                    val serviceIntent = Intent(context, EnhancedBackgroundMonitorService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(serviceIntent)
                    } else {
                        context.startService(serviceIntent)
                    }
                } else {
                    println("🎮 [BOOT] Auto-start disabled or no connection ID found")
                }
            }
        }
    }
}