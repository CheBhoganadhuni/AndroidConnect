package com.connect.androidconnect.service

import android.os.Build
import android.os.FileObserver
import android.util.Log
import com.connect.androidconnect.network.FileManager
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * Watches ALL user-accessible storage recursively (everything under /sdcard except Android/).
 * Fires onFileEvent for both new files (CLOSE_WRITE after create) and updated files (MOVED_TO).
 */
class FileWatcher(
    private val fm: FileManager,
    private val onFileEvent: (JSONObject) -> Unit
) {
    private val TAG = "FileWatcher"
    private val pool = Executors.newSingleThreadExecutor()
    private val observers = mutableListOf<FileObserver>()

    // Directories we never watch — Android internals only
    private val skipDirs = setOf("Android")

    fun start() {
        val root = File(fm.rootPath)
        attachObserversRecursive(root)
        Log.d(TAG, "FileWatcher started — watching ${observers.size} directories")
    }

    fun stop() {
        observers.forEach { it.stopWatching() }
        observers.clear()
    }

    private fun attachObserversRecursive(dir: File) {
        if (!dir.isDirectory) return
        if (dir.name in skipDirs) return

        attachObserver(dir)

        dir.listFiles()
            ?.filter { it.isDirectory && it.name !in skipDirs && !it.name.startsWith('.') }
            ?.forEach { attachObserversRecursive(it) }
    }

    private fun attachObserver(dir: File) {
        val mask = FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO

        val obs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            object : FileObserver(dir, mask) {
                override fun onEvent(event: Int, path: String?) {
                    if (path != null) pool.execute { handleEvent(File(dir, path)) }
                }
            }
        } else {
            @Suppress("DEPRECATION")
            object : FileObserver(dir.absolutePath, mask) {
                override fun onEvent(event: Int, path: String?) {
                    if (path != null) pool.execute { handleEvent(File(dir, path)) }
                }
            }
        }

        obs.startWatching()
        observers.add(obs)
    }

    private fun handleEvent(file: File) {
        if (!file.isFile) return
        if (file.name.startsWith('.') || file.name.endsWith(".tmp")) return
        if (file.length() == 0L) return

        val mime   = fm.mimeType(file.name)
        val source = fm.sourceName(file.parent ?: "")
        val thumb  = fm.generateThumb(file, mime)

        val evt = JSONObject()
            .put("type",     "FILE_CREATED")
            .put("name",     file.name)
            .put("path",     file.absolutePath)
            .put("size",     file.length())
            .put("mime",     mime)
            .put("source",   source)
            .put("modified", file.lastModified())
        if (thumb != null) evt.put("thumb", thumb)

        Log.d(TAG, "File event: ${file.absolutePath}")
        onFileEvent(evt)
    }
}
