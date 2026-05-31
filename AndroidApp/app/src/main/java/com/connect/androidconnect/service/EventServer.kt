package com.connect.androidconnect.service

import android.util.Log
import com.connect.androidconnect.network.Protocol
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Persistent one-way push channel: Android → Mac on port 58001.
 * Mac connects once and sits reading; we write events as they happen.
 * Only one Mac client at a time — if a new one connects the old socket is dropped.
 */
class EventServer {

    private val TAG = "EventServer"
    private var serverSocket: ServerSocket? = null
    private val running = AtomicBoolean(false)
    private val pool = Executors.newCachedThreadPool()

    @Volatile private var clientDos: DataOutputStream? = null
    private val dosLock = Any()

    fun start() {
        running.set(true)
        pool.execute { acceptLoop() }
    }

    fun stop() {
        running.set(false)
        runCatching { serverSocket?.close() }
        synchronized(dosLock) {
            runCatching { clientDos?.close() }
            clientDos = null
        }
    }

    fun push(event: JSONObject) {
        pool.execute {
            synchronized(dosLock) {
                val dos = clientDos ?: return@execute
                try {
                    Protocol.writeMessage(dos, event)
                } catch (e: Exception) {
                    Log.w(TAG, "Push failed (client gone): ${e.message}")
                    clientDos = null
                }
            }
        }
    }

    private fun acceptLoop() {
        try {
            serverSocket = ServerSocket(Protocol.EVENT_PORT)
            Log.d(TAG, "Event server listening on :${Protocol.EVENT_PORT}")
            while (running.get()) {
                val socket = serverSocket?.accept() ?: break
                Log.d(TAG, "Event client connected: ${socket.inetAddress.hostAddress}")
                pool.execute { serveClient(socket) }
            }
        } catch (e: Exception) {
            if (running.get()) Log.e(TAG, "Event server error", e)
        }
    }

    private fun serveClient(socket: Socket) {
        try {
            socket.tcpNoDelay = true
            socket.setSendBufferSize(524_288)
            val dos = DataOutputStream(BufferedOutputStream(socket.getOutputStream(), Protocol.BUFFER_SIZE))
            synchronized(dosLock) {
                runCatching { clientDos?.close() }
                clientDos = dos
            }
            // Block here until client disconnects (we never read from the event channel)
            val input = socket.getInputStream()
            val buf = ByteArray(1)
            while (running.get() && input.read(buf) >= 0) { /* idle */ }
        } catch (e: Exception) {
            Log.d(TAG, "Event client disconnected")
        } finally {
            synchronized(dosLock) { if (clientDos != null) clientDos = null }
            runCatching { socket.close() }
        }
    }
}
