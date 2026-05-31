package com.connect.androidconnect

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.connect.androidconnect.service.ConnectService

// Fires on every device boot — silently starts the background service.
// User never needs to open the app again after first setup.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            context.startForegroundService(Intent(context, ConnectService::class.java))
        }
    }
}
