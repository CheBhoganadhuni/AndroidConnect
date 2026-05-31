package com.connect.androidconnect.service

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONObject

/**
 * System notification listener — mirrors phone notifications to Mac via the event channel.
 * ConnectService wires in the push callback via the companion object.
 */
class NotificationService : NotificationListenerService() {

    private val TAG = "NotificationService"

    companion object {
        // ConnectService sets this when Mac connects; cleared on disconnect
        @Volatile var onNotification: ((JSONObject) -> Unit)? = null

        // Apps whose notifications we never forward (noise/system)
        private val blocklist = setOf(
            "android",
            "com.android.systemui",
            "com.google.android.gms",
            "com.android.phone"
        )
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val cb = onNotification ?: return
        if (sbn.packageName in blocklist) return
        if (sbn.isOngoing) return                          // skip persistent system bars

        val extras = sbn.notification.extras ?: return
        val title = extras.getCharSequence("android.title")?.toString() ?: return
        val text  = extras.getCharSequence("android.text")?.toString() ?: ""

        val appLabel = runCatching {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(sbn.packageName, 0)
            ).toString()
        }.getOrDefault(sbn.packageName)

        val evt = JSONObject()
            .put("type",     "NOTIFICATION")
            .put("app",      sbn.packageName)
            .put("appLabel", appLabel)
            .put("title",    title)
            .put("text",     text)
            .put("key",      sbn.key)
            .put("postTime", sbn.postTime)

        Log.d(TAG, "Forwarding notification: $appLabel › $title")
        cb(evt)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        // Future: push a NOTIFICATION_DISMISSED event so Mac can remove its banner
    }
}
