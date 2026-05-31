package com.connect.androidconnect.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.connect.androidconnect.network.FileManager
import com.connect.androidconnect.network.Protocol
import com.connect.androidconnect.network.SocketServer

class ConnectService : Service() {

    private val TAG = "ConnectService"

    private lateinit var server: SocketServer
    private lateinit var eventServer: EventServer
    private lateinit var fileWatcher: FileWatcher
    private lateinit var batteryMonitor: BatteryMonitor
    private lateinit var nsdManager: NsdManager
    private var registrationListener: NsdManager.RegistrationListener? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        val fm = FileManager(this)
        server = SocketServer(fm, this)
        eventServer = EventServer()
        fileWatcher = FileWatcher(fm) { evt -> eventServer.push(evt) }
        batteryMonitor = BatteryMonitor(this) { evt -> eventServer.push(evt) }
        nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, buildNotification("Waiting for Mac…"))

        server.onConnect = { ip ->
            connectedMacIp = ip
            updateNotification("Mac connected · $ip")
            sendBroadcast(Intent(ACTION_CONNECTED).putExtra("ip", ip))
            NotificationService.onNotification = { evt -> eventServer.push(evt) }
            batteryMonitor.stop()
            batteryMonitor.start()
        }
        server.onDisconnect = {
            connectedMacIp = null
            updateNotification("Waiting for Mac…")
            sendBroadcast(Intent(ACTION_DISCONNECTED))
            NotificationService.onNotification = null
        }

        server.start()
        eventServer.start()
        fileWatcher.start()
        registerMdns()

        return START_STICKY
    }

    override fun onDestroy() {
        server.stop()
        eventServer.stop()
        fileWatcher.stop()
        batteryMonitor.stop()
        NotificationService.onNotification = null
        connectedMacIp = null
        instance = null
        registrationListener?.let { runCatching { nsdManager.unregisterService(it) } }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun registerMdns() {
        val info = NsdServiceInfo().apply {
            serviceName = Protocol.SERVICE_NAME
            serviceType = Protocol.SERVICE_TYPE
            port = Protocol.PORT
        }
        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) { Log.d(TAG, "mDNS up: ${i.serviceName}") }
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) { Log.e(TAG, "mDNS fail: $code") }
            override fun onServiceUnregistered(i: NsdServiceInfo) { Log.d(TAG, "mDNS down") }
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) { Log.e(TAG, "mDNS unreg fail: $code") }
        }
        nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registrationListener!!)
    }

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Connect Service", NotificationManager.IMPORTANCE_LOW)
            )
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Android Connect")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text))
    }

    companion object {
        const val ACTION_CONNECTED    = "com.connect.androidconnect.CONNECTED"
        const val ACTION_DISCONNECTED = "com.connect.androidconnect.DISCONNECTED"
        private const val CHANNEL_ID  = "connect_service"
        private const val NOTIF_ID    = 1

        /** Non-null while Mac is connected; MainActivity reads this on resume to sync UI. */
        @Volatile var connectedMacIp: String? = null

        /** Live service reference (used by NotificationService to push events). */
        @Volatile var instance: ConnectService? = null
    }
}
