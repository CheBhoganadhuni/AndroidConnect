package com.connect.androidconnect

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.connect.androidconnect.BuildConfig
import com.connect.androidconnect.service.ClipboardSyncService
import com.connect.androidconnect.service.ConnectService

class MainActivity : AppCompatActivity() {

    private lateinit var statusDot: View
    private lateinit var statusText: TextView
    private lateinit var deviceIpText: TextView
    private lateinit var toggleBtn: Button

    private lateinit var storagePermCard: LinearLayout
    private lateinit var storagePermBtn: Button
    private lateinit var notifPermCard: LinearLayout
    private lateinit var notifPermBtn: Button
    private lateinit var clipboardPermCard: LinearLayout
    private lateinit var clipboardPermBtn: Button
    private lateinit var versionLabel: Button

    private var serviceRunning = false

    // Polls ConnectService.connectedMacIp while service is running and not yet connected.
    // Supplements the broadcast receiver for faster UI update when Mac connects.
    private val statusHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val statusPoll = object : Runnable {
        override fun run() {
            val ip = ConnectService.connectedMacIp
            if (ip != null) {
                setConnected(true, ip)
            } else if (serviceRunning) {
                statusHandler.postDelayed(this, 500)
            }
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                ConnectService.ACTION_CONNECTED    -> setConnected(true,  intent.getStringExtra("ip"))
                ConnectService.ACTION_DISCONNECTED -> setConnected(false, null)
                ConnectService.ACTION_MAC_NAME     -> {
                    val name = intent.getStringExtra("name") ?: return
                    deviceIpText.text = "Connected to $name"
                }
            }
        }
    }

    private val storagePermLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { refreshPermissionCards() }

    private val notifPermLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { refreshPermissionCards() }

    private var updateChecked = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusDot      = findViewById(R.id.statusDot)
        statusText     = findViewById(R.id.statusText)
        deviceIpText   = findViewById(R.id.deviceIpText)
        toggleBtn      = findViewById(R.id.toggleBtn)
        storagePermCard      = findViewById(R.id.storagePermCard)
        storagePermBtn       = findViewById(R.id.storagePermBtn)
        notifPermCard        = findViewById(R.id.notifPermCard)
        notifPermBtn         = findViewById(R.id.notifPermBtn)
        clipboardPermCard    = findViewById(R.id.clipboardPermCard)
        clipboardPermBtn     = findViewById(R.id.clipboardPermBtn)
        versionLabel         = findViewById(R.id.versionLabel)

        versionLabel.text = "Check for Updates · v${BuildConfig.VERSION_NAME}"
        versionLabel.setOnClickListener { UpdateChecker.checkManually(this) }

        toggleBtn.setOnClickListener { toggleService() }
        storagePermBtn.setOnClickListener { requestStoragePermission() }
        notifPermBtn.setOnClickListener { openNotificationListenerSettings() }
        clipboardPermBtn.setOnClickListener {
            val expected = ComponentName(this, ClipboardSyncService::class.java).flattenToString()
            val flat = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
            val a11yEnabled = flat.split(":").any { it.equals(expected, ignoreCase = true) }
            if (!a11yEnabled) {
                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            } else if (!Settings.canDrawOverlays(this)) {
                startActivity(Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                ))
            }
        }

        val filter = IntentFilter().apply {
            addAction(ConnectService.ACTION_CONNECTED)
            addAction(ConnectService.ACTION_DISCONNECTED)
            addAction(ConnectService.ACTION_MAC_NAME)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }

        requestPostNotificationsIfNeeded()

        // Auto-start the service on first open — user shouldn't have to press anything
        autoStartService()
    }

    override fun onResume() {
        super.onResume()
        refreshPermissionCards()
        if (!updateChecked) { updateChecked = true; UpdateChecker.checkOnce(this) }

        // Sync immediately if already connected
        val ip = ConnectService.connectedMacIp
        if (ip != null) {
            setConnected(true, ip)
            ConnectService.connectedMacName?.let { deviceIpText.text = "Connected to $it" }
        } else if (serviceRunning) {
            // Poll every 500ms until Mac connects — supplements the broadcast receiver
            statusHandler.removeCallbacks(statusPoll)
            statusHandler.postDelayed(statusPoll, 500)
        }
    }

    override fun onPause() {
        statusHandler.removeCallbacks(statusPoll)
        super.onPause()
    }

    override fun onDestroy() {
        unregisterReceiver(receiver)
        super.onDestroy()
    }

    // MARK: - Service lifecycle

    private fun autoStartService() {
        if (!serviceRunning) {
            startForegroundService(Intent(this, ConnectService::class.java))
            serviceRunning = true
            toggleBtn.text  = "Stop Service"
            statusText.text = "Waiting for Mac…"
            statusDot.setBackgroundColor(Color.parseColor("#F5A623"))
            statusHandler.removeCallbacks(statusPoll)
            statusHandler.postDelayed(statusPoll, 500)
        }
    }

    private fun toggleService() {
        if (serviceRunning) {
            stopService(Intent(this, ConnectService::class.java))
            serviceRunning = false
            statusHandler.removeCallbacks(statusPoll)
            toggleBtn.text = "Start Service"
            statusText.text = "Service stopped"
            deviceIpText.text = ""
            statusDot.setBackgroundColor(Color.parseColor("#CCCCCC"))
        } else {
            startForegroundService(Intent(this, ConnectService::class.java))
            serviceRunning = true
            toggleBtn.text = "Stop Service"
            statusText.text = "Waiting for Mac…"
            statusDot.setBackgroundColor(Color.parseColor("#F5A623"))
            statusHandler.removeCallbacks(statusPoll)
            statusHandler.postDelayed(statusPoll, 500)
        }
    }

    private fun setConnected(connected: Boolean, ip: String?) {
        if (connected) {
            statusDot.setBackgroundColor(Color.parseColor("#4CAF50"))
            statusText.text = "Mac connected"
            deviceIpText.text = "Mac IP: $ip"
        } else {
            statusDot.setBackgroundColor(Color.parseColor("#F5A623"))
            statusText.text = "Waiting for Mac…"
            deviceIpText.text = ""
        }
    }

    // MARK: - Permission checks

    private fun refreshPermissionCards() {
        storagePermCard.visibility   = if (hasStoragePermission()) View.GONE else View.VISIBLE
        notifPermCard.visibility     = if (isNotificationListenerEnabled()) View.GONE else View.VISIBLE
        clipboardPermCard.visibility = if (isClipboardAccessibilityEnabled()) View.GONE else View.VISIBLE
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
            ?: return false
        return flat.split(":").any { it.contains(packageName) }
    }

    private fun isClipboardAccessibilityEnabled(): Boolean {
        val expected = ComponentName(this, ClipboardSyncService::class.java).flattenToString()
        val flat = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?: return false
        val a11yEnabled = flat.split(":").any { it.equals(expected, ignoreCase = true) }
        return a11yEnabled && Settings.canDrawOverlays(this)
    }

    private fun requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startActivity(Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName")
            ))
        } else {
            storagePermLauncher.launch(arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ))
        }
    }

    private fun openNotificationListenerSettings() {
        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    }

    private fun requestPostNotificationsIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            notifPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}
