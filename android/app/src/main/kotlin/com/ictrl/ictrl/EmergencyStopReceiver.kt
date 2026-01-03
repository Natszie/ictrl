package com.ictrl.ictrl

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.app.NotificationManager

class EmergencyStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        println("🎮 [EMERGENCY] Emergency stop triggered")
        EnhancedBackgroundMonitorService.stopService(context)

        // Clear all notifications
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancelAll()
    }

}