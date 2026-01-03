package com.ictrl.ictrl

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent

class ICTRLDeviceAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        super.onEnabled(context, intent)
        println("🎮 🛡️ [ADMIN] Device admin enabled for iCTRL")
    }

    override fun onDisabled(context: Context, intent: Intent) {
        super.onDisabled(context, intent)
        println("🎮 🛡️ [ADMIN] Device admin disabled for iCTRL")
    }

    override fun onDisableRequested(context: Context, intent: Intent): CharSequence {
        println("🎮 🛡️ [ADMIN] Device admin disable requested")
        return "Disabling iCTRL device admin will reduce parental control effectiveness. Are you sure?"
    }

}