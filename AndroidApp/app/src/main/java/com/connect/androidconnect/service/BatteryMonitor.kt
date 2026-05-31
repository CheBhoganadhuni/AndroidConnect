package com.connect.androidconnect.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.util.Log
import org.json.JSONObject

/**
 * Broadcasts battery level + charging state whenever it changes.
 * Pushes a BATTERY event to the event channel on each meaningful change.
 */
class BatteryMonitor(
    private val context: Context,
    private val onChanged: (JSONObject) -> Unit
) {

    private val TAG = "BatteryMonitor"
    private var lastLevel = -1

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val level   = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale   = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
            val status  = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            val pct     = if (scale > 0) level * 100 / scale else -1
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                           status == BatteryManager.BATTERY_STATUS_FULL

            if (pct != lastLevel) {
                lastLevel = pct
                Log.d(TAG, "Battery: $pct% charging=$charging")
                onChanged(JSONObject()
                    .put("type",     "BATTERY")
                    .put("level",    pct)
                    .put("charging", charging))
            }
        }
    }

    fun start() {
        context.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        // Push current level immediately so Mac shows battery on connect
        pushCurrent()
    }

    fun stop() {
        runCatching { context.unregisterReceiver(receiver) }
    }

    private fun pushCurrent() {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return
        val level   = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale   = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val status  = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val pct     = if (scale > 0) level * 100 / scale else -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                       status == BatteryManager.BATTERY_STATUS_FULL
        lastLevel = pct
        onChanged(JSONObject()
            .put("type",     "BATTERY")
            .put("level",    pct)
            .put("charging", charging))
    }
}
