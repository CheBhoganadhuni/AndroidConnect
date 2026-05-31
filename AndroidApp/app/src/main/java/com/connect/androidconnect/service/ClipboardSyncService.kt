package com.connect.androidconnect.service

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.os.Build
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.graphics.PixelFormat
import android.graphics.Color
import android.provider.Settings

/**
 * AccessibilityService that reads clipboard in background on Android 10+.
 * Calls startForeground() to prevent OPPO/OnePlus background optimizer from
 * unbinding it. Momentarily gains focus using a 1x1 translucent overlay window
 * of type TYPE_APPLICATION_OVERLAY to bypass AppOp 29 clipboard background blocks.
 */
class ClipboardSyncService : AccessibilityService() {

    private val TAG = "ClipboardSyncService"
    private var clipboardManager: ClipboardManager? = null
    private var lastSentClip = ""
    private val pollHandler = Handler(android.os.Looper.getMainLooper())
    private var lastEventTime = 0L
    private var overlayView: View? = null

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        Log.d(TAG, "OnPrimaryClipChangedListener fired")
        readAndPush()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.e(TAG, "onServiceConnected — clipboard accessibility sync engine initialized")
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboardManager = cm
        cm.addPrimaryClipChangedListener(clipListener)
        startForegroundSelf()
    }

    private fun startForegroundSelf() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Clipboard Sync", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Android Connect")
            .setContentText("Clipboard sync active")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notification)
    }

    private fun readDirectly() {
        val cm = clipboardManager ?: return
        if (!cm.hasPrimaryClip()) return
        val text = try {
            cm.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString() ?: return
        } catch (e: Exception) {
            Log.d(TAG, "Clipboard read bypassed/denied in background: ${e.message}")
            return
        }
        if (text.isEmpty() || text == lastSentClip) return
        lastSentClip = text
        Log.e(TAG, "Clip changed → pushing: ${text.take(80)}")
        ConnectService.instance?.pushClipboardIfNew(text)
    }

    private fun readWithFocusOverlay() {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        
        // If there's an existing overlay, clean it up first
        overlayView?.let {
            try {
                wm.removeView(it)
            } catch (e: Exception) {
                Log.d(TAG, "Exception removing old overlay: ${e.message}")
            }
        }

        var removed = false
        lateinit var removeRunnable: Runnable

        val view = object : View(this) {
            override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
                super.onWindowFocusChanged(hasWindowFocus)
                if (hasWindowFocus) {
                    Log.d(TAG, "Overlay gained focus. Reading clipboard.")
                    readDirectly()
                    
                    if (!removed) {
                        removed = true
                        pollHandler.removeCallbacks(removeRunnable)
                        if (overlayView === this) {
                            overlayView = null
                        }
                        try {
                            val wm2 = getSystemService(Context.WINDOW_SERVICE) as WindowManager
                            wm2.removeView(this)
                            Log.d(TAG, "Overlay removed after reading.")
                        } catch (e: Exception) {
                            Log.d(TAG, "Overlay remove exception: ${e.message}")
                        }
                    }
                }
            }
        }
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        overlayView = view

        val windowType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            1, 1, // 1x1 pixel size
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.LEFT or Gravity.TOP
            x = 0
            y = 0
        }

        removeRunnable = Runnable {
            if (!removed) {
                removed = true
                if (overlayView === view) {
                    overlayView = null
                }
                try {
                    wm.removeView(view)
                    Log.d(TAG, "Overlay removed via safety timeout")
                } catch (e: Exception) {
                    Log.d(TAG, "Overlay remove timeout exception: ${e.message}")
                }
            }
        }

        try {
            wm.addView(view, params)
            view.requestFocus()
            Log.d(TAG, "Overlay view added to gain focus")
            pollHandler.postDelayed(removeRunnable, 200)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add focus overlay: ${e.message}. Falling back to direct read.")
            readDirectly()
        }
    }

    private fun readAndPush() {
        readWithFocusOverlay()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        
        // Filter events to avoid unnecessary polling and focus stealing while user types
        val eventType = event.eventType
        if (eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED || 
            eventType == AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED) {
            
            val now = System.currentTimeMillis()
            if (now - lastEventTime > 3000) { // 3-second rate limit
                lastEventTime = now
                Log.d(TAG, "onAccessibilityEvent ($eventType) matches filter, checking clipboard")
                readAndPush()
            }
        }
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        pollHandler.removeCallbacksAndMessages(null)
        overlayView?.let {
            try {
                val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
                wm.removeView(it)
            } catch (e: Exception) {
                Log.d(TAG, "Exception cleaning up overlay in onDestroy: ${e.message}")
            }
            overlayView = null
        }
        clipboardManager?.removePrimaryClipChangedListener(clipListener)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "clipboard_sync_service"
        private const val NOTIF_ID = 2
    }
}
