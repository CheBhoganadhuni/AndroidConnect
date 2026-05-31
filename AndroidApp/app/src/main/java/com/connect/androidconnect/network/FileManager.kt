package com.connect.androidconnect.network

import android.content.Context
import android.graphics.Bitmap
import android.media.ThumbnailUtils
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

class FileManager(private val context: Context) {

    val rootPath: String = Environment.getExternalStorageDirectory().absolutePath

    // Directories we never show in the file browser (Android internals)
    private val hiddenDirs = setOf("Android")

    fun listDirectory(path: String): JSONObject {
        val safe = safePath(path)
        val dir = File(safe)
        val items = JSONArray()

        dir.listFiles()
            ?.filter { f -> !(f.isDirectory && hiddenDirs.contains(f.name)) }
            ?.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
            ?.forEach { f ->
                items.put(JSONObject().apply {
                    put("name", f.name)
                    put("isDir", f.isDirectory)
                    put("size", if (f.isFile) f.length() else 0L)
                    put("modified", f.lastModified())
                    put("path", f.absolutePath)
                })
            }

        return JSONObject()
            .put("type", "DIR_LIST")
            .put("path", safe)
            .put("items", items)
    }

    fun storageInfo(): JSONObject {
        val stat = StatFs(rootPath)
        return JSONObject()
            .put("type", "STORAGE_INFO")
            .put("total", stat.totalBytes)
            .put("free", stat.availableBytes)
            .put("used", stat.totalBytes - stat.availableBytes)
            .put("root", rootPath)
    }

    fun file(path: String): File = File(safePath(path))

    fun destFile(dir: String, name: String): File {
        val d = File(safePath(dir))
        d.mkdirs()
        return File(d, name.replace("/", "_"))
    }

    // Returns the N most-recently-modified files across ALL user storage (except Android/)
    fun getRecentFiles(limit: Int = 20): JSONObject {
        val files = mutableListOf<File>()
        File(rootPath).walkTopDown()
            .onEnter { dir -> dir.name != "Android" && !dir.name.startsWith('.') }
            .filter { it.isFile && !it.name.startsWith('.') && !it.name.endsWith(".tmp") }
            .forEach { files.add(it) }

        val sorted = files.sortedByDescending { it.lastModified() }.take(limit)

        val arr = JSONArray()
        for (f in sorted) {
            val mime = mimeType(f.name)
            val obj = JSONObject()
                .put("name", f.name)
                .put("path", f.absolutePath)
                .put("size", f.length())
                .put("modified", f.lastModified())
                .put("mime", mime)
                .put("source", sourceName(f.parent ?: ""))
            val thumb = generateThumb(f, mime)
            if (thumb != null) obj.put("thumb", thumb)
            arr.put(obj)
        }

        return JSONObject().put("type", "RECENT_FILES").put("files", arr)
    }

    // Returns count of files by type across the device
    fun getFileCounts(): JSONObject {
        var images = 0; var videos = 0; var audio = 0
        var documents = 0; var archives = 0; var apks = 0

        File(rootPath).walkTopDown()
            .onEnter { dir -> dir.name != "Android" && !dir.name.startsWith('.') }
            .filter { it.isFile && !it.name.startsWith('.') && !it.name.endsWith(".tmp") }
            .forEach { f ->
                when (mimeCategory(f.name)) {
                    "image"    -> images++
                    "video"    -> videos++
                    "audio"    -> audio++
                    "document" -> documents++
                    "archive"  -> archives++
                    "apk"      -> apks++
                }
            }

        return JSONObject()
            .put("type", "FILE_COUNTS")
            .put("images", images)
            .put("videos", videos)
            .put("audio", audio)
            .put("documents", documents)
            .put("archives", archives)
            .put("apks", apks)
    }

    // Returns a base64 JPEG thumbnail for a given file path
    // Returns files matching a type filter across all user storage
    fun getFilesByType(type: String, offset: Int = 0, limit: Int = 200): JSONObject {
        val extensions: Set<String> = when (type.lowercase()) {
            "images"    -> setOf("jpg","jpeg","png","gif","heic","heif","webp","bmp","tiff","svg")
            "videos"    -> setOf("mp4","mov","mkv","avi","wmv","flv","3gp","webm","ts")
            "audio"     -> setOf("mp3","m4a","flac","wav","ogg","aac","wma","opus","amr")
            "documents" -> setOf("pdf","doc","docx","xls","xlsx","ppt","pptx","txt","csv","rtf","epub")
            "archives"  -> setOf("zip","rar","7z","tar","gz","bz2","xz")
            "apks"      -> setOf("apk")
            else        -> emptySet()
        }
        val files = File(rootPath).walkTopDown()
            .onEnter { d -> d.name != "Android" && !d.name.startsWith('.') }
            .filter { it.isFile && it.extension.lowercase() in extensions && !it.name.startsWith('.') }
            .sortedByDescending { it.lastModified() }
            .drop(offset).take(limit).toList()

        val arr = JSONArray()
        files.forEach { f ->
            arr.put(JSONObject()
                .put("name",     f.name)
                .put("path",     f.absolutePath)
                .put("size",     f.length())
                .put("modified", f.lastModified())
                .put("mime",     mimeType(f.name))
                .put("isDir",    false))
        }
        return JSONObject().put("type","FILE_LIST").put("fileType",type).put("items",arr)
    }

    // Returns directory listing for a named source folder
    fun getFilesBySource(source: String): JSONObject {
        val dir: File = when (source.lowercase()) {
            "downloads" -> File("$rootPath/Download").let { if (it.isDirectory) it else File("$rootPath/Downloads") }
            "dcim"      -> File("$rootPath/DCIM")
            "whatsapp"  -> File("$rootPath/WhatsApp")
            "bluetooth" -> File("$rootPath/Bluetooth")
            else        -> File(rootPath)
        }
        return if (dir.isDirectory) listDirectory(dir.absolutePath)
        else JSONObject().put("type","DIR_LIST").put("path",dir.absolutePath).put("items", JSONArray())
    }

    fun getThumbnail(path: String): JSONObject {
        val f = File(safePath(path))
        if (!f.isFile) return JSONObject().put("type", "ERROR").put("msg", "Not a file")
        val mime = mimeType(f.name)
        val thumb = generateThumb(f, mime)
            ?: return JSONObject().put("type", "ERROR").put("msg", "No thumbnail")
        return JSONObject().put("type", "THUMBNAIL").put("data", thumb)
    }

    fun generateThumb(file: File, mime: String): String? {
        return try {
            val bmp: Bitmap? = when {
                mime.startsWith("image/") -> {
                    val opts = android.graphics.BitmapFactory.Options().apply { inSampleSize = 4 }
                    val full = android.graphics.BitmapFactory.decodeFile(file.absolutePath, opts)
                    full?.let { ThumbnailUtils.extractThumbnail(it, 160, 160) }
                }
                mime.startsWith("video/") -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        ThumbnailUtils.createVideoThumbnail(file, android.util.Size(160, 160), null)
                    } else {
                        @Suppress("DEPRECATION")
                        ThumbnailUtils.createVideoThumbnail(file.absolutePath, MediaStore.Images.Thumbnails.MINI_KIND)
                    }
                }
                else -> null
            }
            bmp?.let {
                val baos = ByteArrayOutputStream()
                it.compress(Bitmap.CompressFormat.JPEG, 80, baos)
                Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
            }
        } catch (e: Exception) { null }
    }

    fun mimeType(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "jpg", "jpeg" -> "image/jpeg"
            "png"         -> "image/png"
            "gif"         -> "image/gif"
            "heic", "heif"-> "image/heic"
            "webp"        -> "image/webp"
            "mp4"         -> "video/mp4"
            "mov"         -> "video/quicktime"
            "mkv"         -> "video/x-matroska"
            "avi"         -> "video/avi"
            "mp3"         -> "audio/mpeg"
            "m4a"         -> "audio/m4a"
            "flac"        -> "audio/flac"
            "wav"         -> "audio/wav"
            "ogg"         -> "audio/ogg"
            "pdf"         -> "application/pdf"
            "doc","docx"  -> "application/msword"
            "xls","xlsx"  -> "application/vnd.ms-excel"
            "ppt","pptx"  -> "application/vnd.ms-powerpoint"
            "txt"         -> "text/plain"
            "zip"         -> "application/zip"
            "rar"         -> "application/x-rar-compressed"
            "7z"          -> "application/x-7z-compressed"
            "tar","gz"    -> "application/gzip"
            "apk"         -> "application/vnd.android.package-archive"
            else          -> "application/octet-stream"
        }
    }

    private fun mimeCategory(name: String): String {
        val mime = mimeType(name)
        return when {
            mime.startsWith("image/") -> "image"
            mime.startsWith("video/") -> "video"
            mime.startsWith("audio/") -> "audio"
            mime == "application/vnd.android.package-archive" -> "apk"
            mime in listOf("application/zip","application/x-rar-compressed",
                           "application/x-7z-compressed","application/gzip") -> "archive"
            mime.startsWith("application/") || mime.startsWith("text/") -> "document"
            else -> "other"
        }
    }

    fun sourceName(dir: String): String = when {
        dir.contains("DCIM")      -> "DCIM"
        dir.contains("WhatsApp")  -> "WhatsApp"
        dir.contains("Download")  -> "Downloads"
        dir.contains("Bluetooth") -> "Bluetooth"
        dir.contains("Pictures")  -> "Pictures"
        else                      -> "Other"
    }

    private fun safePath(path: String): String {
        val canon = File(path).canonicalPath
        return if (canon.startsWith(rootPath)) canon else rootPath
    }
}
