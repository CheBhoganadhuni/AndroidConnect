package com.connect.androidconnect.network

import android.content.Context
import android.media.MediaScannerConnection
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class SocketServer(private val fm: FileManager, private val context: Context) {

    private val TAG = "SocketServer"
    private var serverSocket: ServerSocket? = null
    @Volatile private var currentClientSocket: Socket? = null
    private val running = AtomicBoolean(false)
    private val pool = Executors.newCachedThreadPool()

    var onConnect: ((String) -> Unit)? = null
    var onDisconnect: (() -> Unit)? = null

    fun start() {
        running.set(true)
        pool.execute { acceptLoop() }
    }

    fun stop() {
        running.set(false)
        // Close the active client socket first so handleClient unblocks immediately
        // and fires onDisconnect — without this, handleClient stays blocked in readMessage.
        runCatching { currentClientSocket?.close() }
        runCatching { serverSocket?.close() }
    }

    private fun acceptLoop() {
        try {
            serverSocket = ServerSocket(Protocol.PORT)
            Log.d(TAG, "Listening on :${Protocol.PORT}")
            while (running.get()) {
                val socket = serverSocket?.accept() ?: break
                Log.d(TAG, "Mac connected: ${socket.inetAddress.hostAddress}")
                onConnect?.invoke(socket.inetAddress.hostAddress ?: "unknown")
                pool.execute { handleClient(socket) }
            }
        } catch (e: Exception) {
            if (running.get()) Log.e(TAG, "Server error", e)
        }
    }

    private fun handleClient(socket: Socket) {
        currentClientSocket = socket
        try {
            socket.use {
                val dis = DataInputStream(BufferedInputStream(socket.getInputStream(), Protocol.BUFFER_SIZE))
                val dos = DataOutputStream(BufferedOutputStream(socket.getOutputStream(), Protocol.BUFFER_SIZE))
                while (running.get() && !socket.isClosed) {
                    val msg = runCatching { Protocol.readMessage(dis) }.getOrNull() ?: break
                    runCatching { dispatch(msg, dis, dos) }.onFailure { e ->
                        if (running.get()) Log.e(TAG, "Dispatch error", e)
                        return@use
                    }
                }
            }
        } catch (e: Exception) {
            if (running.get()) Log.e(TAG, "Client error", e)
        } finally {
            currentClientSocket = null
            Log.d(TAG, "Mac disconnected")
            onDisconnect?.invoke()
        }
    }

    private fun dispatch(msg: JSONObject, dis: DataInputStream, dos: DataOutputStream) {
        when (msg.optString("cmd")) {

            "PING" -> Protocol.writeMessage(dos, JSONObject().put("type", "PONG"))

            "STORAGE_INFO" -> Protocol.writeMessage(dos, fm.storageInfo())

            "LIST_DIR" -> {
                val path = msg.optString("path", fm.rootPath)
                Protocol.writeMessage(dos, fm.listDirectory(path))
            }

            "GET_FILE" -> {
                val file = fm.file(msg.getString("path"))
                if (!file.isFile) {
                    Protocol.writeMessage(dos, JSONObject().put("type", "ERROR").put("msg", "File not found"))
                    return
                }
                Protocol.writeMessage(dos, JSONObject()
                    .put("type", "FILE_START")
                    .put("name", file.name)
                    .put("size", file.length()))
                file.inputStream().buffered(Protocol.BUFFER_SIZE).use { it.copyTo(dos, Protocol.BUFFER_SIZE) }
                dos.flush()
            }

            "PUT_FILE" -> {
                val name = msg.getString("name")
                val size = msg.getLong("size")
                val destDir = msg.optString("dest_path", "${fm.rootPath}/AndroidConnect")
                val outFile = fm.destFile(destDir, name)

                Protocol.writeMessage(dos, JSONObject().put("type", "READY"))

                outFile.outputStream().buffered(Protocol.BUFFER_SIZE).use { out ->
                    var remaining = size
                    val buf = ByteArray(Protocol.BUFFER_SIZE)
                    while (remaining > 0) {
                        val n = dis.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                        if (n < 0) break
                        out.write(buf, 0, n)
                        remaining -= n
                    }
                }
                Protocol.writeMessage(dos, JSONObject()
                    .put("type", "PUT_DONE")
                    .put("path", outFile.absolutePath))

                // Index the file so it appears immediately in Gallery / Files
                MediaScannerConnection.scanFile(context, arrayOf(outFile.absolutePath), null, null)
            }

            "GET_DEVICE_INFO" -> {
                // User-set device name (Bluetooth / Wi-Fi hotspot name) or fall back to model
                val deviceName = android.provider.Settings.Global.getString(
                    context.contentResolver, "device_name"
                ) ?: android.os.Build.MODEL
                Protocol.writeMessage(dos,
                    org.json.JSONObject()
                        .put("type", "DEVICE_INFO")
                        .put("model", deviceName))
            }

            "GET_THUMBNAIL" -> {
                val path = msg.getString("path")
                Protocol.writeMessage(dos, fm.getThumbnail(path))
            }

            "GET_RECENT_FILES" -> {
                val limit = msg.optInt("limit", 20)
                Protocol.writeMessage(dos, fm.getRecentFiles(limit))
            }

            "GET_FILE_COUNTS" -> {
                Protocol.writeMessage(dos, fm.getFileCounts())
            }

            "GET_FILES_BY_TYPE" -> {
                val type   = msg.optString("type", "images")
                val offset = msg.optInt("offset", 0)
                val limit  = msg.optInt("limit", 200)
                Protocol.writeMessage(dos, fm.getFilesByType(type, offset, limit))
            }

            "GET_FILES_BY_SOURCE" -> {
                val source = msg.optString("source", "downloads")
                Protocol.writeMessage(dos, fm.getFilesBySource(source))
            }
        }
    }
}
