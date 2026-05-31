package com.connect.androidconnect

import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

// Checks github.com/CheBhoganadhuni/AndroidConnect/releases/latest for a newer APK.
//
// Publishing an Android update:
//   1. Bump versionCode + versionName in app/build.gradle
//   2. Build release APK (or debug for now): bash build_apk.sh
//   3. gh release create v<X.Y.Z> app-debug.apk --title "v<X.Y.Z>" --notes "..."
//      (name the asset something like AndroidConnect-v1.0.1.apk so we find it by .apk suffix)
//   4. Users tap "Update" in the app → system installer handles the rest.

object UpdateChecker {

    private const val TAG = "UpdateChecker"
    private const val API =
        "https://api.github.com/repos/CheBhoganadhuni/AndroidConnect/releases/latest"

    /** Silent auto-check on launch — only shows dialog when an update is found. */
    fun checkOnce(context: Context) = check(context, silent = true)

    /** Manual check triggered by tapping the version label — always shows result. */
    fun checkManually(context: Context) = check(context, silent = false)

    private fun check(context: Context, silent: Boolean) {
        Thread {
            try {
                val conn = URL(API).openConnection() as HttpURLConnection
                conn.setRequestProperty("Accept", "application/vnd.github.v3+json")
                conn.connectTimeout = 8_000
                conn.readTimeout    = 8_000
                if (conn.responseCode != 200) {
                    if (!silent) Handler(Looper.getMainLooper()).post {
                        showInfo(context, "Update check failed", "Could not reach GitHub. Check your connection.")
                    }
                    return@Thread
                }

                val json    = JSONObject(conn.inputStream.bufferedReader().readText())
                val tag     = json.optString("tag_name") ?: return@Thread
                val version = if (tag.startsWith("v")) tag.drop(1) else tag

                if (!isNewer(version, BuildConfig.VERSION_NAME)) {
                    if (!silent) Handler(Looper.getMainLooper()).post {
                        showInfo(context, "You're up to date!",
                            "Android Connect v${BuildConfig.VERSION_NAME} is the latest version.")
                    }
                    return@Thread
                }

                // Find first .apk asset
                val assets = json.optJSONArray("assets") ?: return@Thread
                var apkUrl: String? = null
                for (i in 0 until assets.length()) {
                    val a = assets.getJSONObject(i)
                    if (a.optString("name").endsWith(".apk")) {
                        apkUrl = a.optString("browser_download_url")
                        break
                    }
                }
                if (apkUrl == null) {
                    if (!silent) Handler(Looper.getMainLooper()).post {
                        showInfo(context, "You're up to date!",
                            "Android Connect v${BuildConfig.VERSION_NAME} is the latest Android version.")
                    }
                    return@Thread
                }

                val url = apkUrl
                Handler(Looper.getMainLooper()).post {
                    showUpdateDialog(context, tag, url)
                }
            } catch (e: Exception) {
                Log.d(TAG, "Update check failed: ${e.message}")
                if (!silent) Handler(Looper.getMainLooper()).post {
                    showInfo(context, "Update check failed", e.message ?: "Unknown error")
                }
            }
        }.start()
    }

    private fun showInfo(context: Context, title: String, message: String) {
        AlertDialog.Builder(context)
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton("OK", null)
            .show()
    }

    private fun showUpdateDialog(context: Context, tag: String, apkUrl: String) {
        AlertDialog.Builder(context)
            .setTitle("Update available: $tag")
            .setMessage("A new version of Android Connect is available. Download and install now?")
            .setPositiveButton("Download & Install") { _, _ -> downloadAndInstall(context, apkUrl) }
            .setNegativeButton("Later", null)
            .show()
    }

    private fun downloadAndInstall(context: Context, apkUrl: String) {
        val progress = AlertDialog.Builder(context)
            .setTitle("Downloading…")
            .setMessage("Please wait")
            .setCancelable(false)
            .create()
        progress.show()

        Thread {
            try {
                val dest = File(context.cacheDir, "AndroidConnect_update.apk")
                val conn = URL(apkUrl).openConnection() as HttpURLConnection
                conn.inputStream.use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }

                Handler(Looper.getMainLooper()).post {
                    progress.dismiss()
                    launchInstaller(context, dest)
                }
            } catch (e: Exception) {
                Handler(Looper.getMainLooper()).post {
                    progress.dismiss()
                    AlertDialog.Builder(context)
                        .setTitle("Download failed")
                        .setMessage(e.message ?: "Unknown error")
                        .setPositiveButton("OK", null)
                        .show()
                }
            }
        }.start()
    }

    private fun launchInstaller(context: Context, apk: File) {
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            apk
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    private fun isNewer(a: String, b: String): Boolean {
        val pa = a.split(".").mapNotNull { it.toIntOrNull() }
        val pb = b.split(".").mapNotNull { it.toIntOrNull() }
        for (i in 0 until maxOf(pa.size, pb.size)) {
            val av = pa.getOrElse(i) { 0 }
            val bv = pb.getOrElse(i) { 0 }
            if (av > bv) return true
            if (av < bv) return false
        }
        return false
    }
}
